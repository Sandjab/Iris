import ArgumentParser
import Foundation
import IrisKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Run health checks against the daemon and local environment."
    )

    @OptionGroup var connection: ConnectionOptions
    @Flag(name: .customLong("json")) var json: Bool = false

    // MARK: - Types

    enum Severity: String, Codable, Sendable {
        case ok, warn, fail
    }

    struct CheckResult: Codable, Sendable {
        let name: String
        let severity: Severity
        let detail: String
    }

    // MARK: - Run

    mutating func run() async throws {
        var results: [CheckResult] = []

        let socketPath: String
        do {
            socketPath = try connection.resolvedSocketPath()
        } catch {
            results.append(.init(name: "socket-path-resolution", severity: .fail, detail: "\(error)"))
            emit(results)
            throw ExitCode(IrisExitCode.logicError)
        }

        // 1. admin-socket-present
        if FileManager.default.fileExists(atPath: socketPath) {
            results.append(.init(name: "admin-socket-present", severity: .ok, detail: socketPath))
        } else {
            results.append(.init(name: "admin-socket-present", severity: .fail, detail: "missing: \(socketPath)"))
            emit(results)
            throw ExitCode(IrisExitCode.daemonUnreachable)
        }

        // Collect daemon info via RPC. withAdminClient throws ExitCode(2) on connect failure,
        // which propagates directly (desired). Any other error becomes a fail result.
        var status: DaemonStatus?
        var caPath: String?
        var caTrusted: Bool?
        var brokerListen: String?

        do {
            (status, caPath, caTrusted, brokerListen) = try await withAdminClient(connection) { client in
                let st = try await client.call(.daemonStatus, returning: DaemonStatus.self)
                let pathResult = try await client.call(.caExportPath, returning: CAExportPathResult.self)
                let trustResult = try await client.call(.caIsTrusted, returning: CAIsTrustedResult.self)
                let cfg = try await client.call(.configGet, returning: Config.self)
                return (st, pathResult.path, trustResult.trusted, cfg.broker.listen)
            }
        } catch let code as ExitCode {
            // ExitCode(2) from withAdminClient (daemon unreachable) — propagate directly.
            throw code
        } catch {
            results.append(.init(name: "daemon-rpc", severity: .fail, detail: "\(error)"))
            emit(results)
            throw ExitCode(IrisExitCode.logicError)
        }

        // 2. daemon-alive (kill -0 to confirm pid is responding)
        if let st = status {
            let alive = kill(st.pid, 0) == 0
            results.append(
                .init(
                    name: "daemon-alive",
                    severity: alive ? .ok : .fail,
                    detail: "pid=\(st.pid) uptime=\(TextFormatter.uptime(seconds: st.uptimeS))"
                )
            )
        }

        // 3. ca-cert-present
        if let p = caPath {
            if FileManager.default.fileExists(atPath: p) {
                results.append(.init(name: "ca-cert-present", severity: .ok, detail: p))
            } else {
                results.append(.init(name: "ca-cert-present", severity: .fail, detail: "missing: \(p)"))
            }
        }

        // 4. ca-trusted-system
        if let trusted = caTrusted {
            results.append(
                .init(
                    name: "ca-trusted-system",
                    severity: trusted ? .ok : .fail,
                    detail: trusted
                        ? "in user trust store"
                        : "not in user trust store — run: security add-trusted-cert ..."
                )
            )
        }

        // 5. shell-env-vars (warn, not fail, when any are absent)
        let env = ProcessInfo.processInfo.environment
        let expected = ["HTTPS_PROXY", "HTTP_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"]
        let missing = expected.filter { env[$0]?.isEmpty ?? true }
        if missing.isEmpty {
            results.append(.init(name: "shell-env-vars", severity: .ok, detail: "all set"))
        } else {
            results.append(
                .init(
                    name: "shell-env-vars",
                    severity: .warn,
                    detail: "missing: \(missing.joined(separator: ","))"
                )
            )
        }

        // 6. proxy-ping — GET http://<broker.listen>/__iris_ping, expect 200 + "ok\n"
        if let listen = brokerListen {
            guard let pingURL = URL(string: "http://\(listen)/__iris_ping") else {
                results.append(
                    .init(
                        name: "proxy-ping",
                        severity: .fail,
                        detail: "invalid broker.listen: \(listen)"
                    )
                )
                emit(results)
                throw ExitCode(IrisExitCode.logicError)
            }
            let pingResult = await performPing(url: pingURL)
            results.append(
                .init(
                    name: "proxy-ping",
                    severity: pingResult.ok ? .ok : .fail,
                    detail: pingResult.detail
                )
            )
        }

        // 7. claude-apikeyhelper-absent — fail if ~/.claude/settings.json contains "apiKeyHelper"
        let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        if FileManager.default.fileExists(atPath: claudeSettings) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettings)),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["apiKeyHelper"] != nil
            {
                results.append(
                    .init(
                        name: "claude-apikeyhelper-absent",
                        severity: .fail,
                        detail: "apiKeyHelper set in \(claudeSettings) — incompatible (SPECS Annex A.11)"
                    )
                )
            } else {
                results.append(.init(name: "claude-apikeyhelper-absent", severity: .ok, detail: "not set"))
            }
        } else {
            results.append(
                .init(
                    name: "claude-apikeyhelper-absent",
                    severity: .ok,
                    detail: "no settings.json"
                )
            )
        }

        emit(results)
        if results.contains(where: { $0.severity == .fail }) {
            throw ExitCode(IrisExitCode.logicError)
        }
    }

    // MARK: - Helpers

    private func performPing(url: URL) async -> (ok: Bool, detail: String) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? ""
            let ok = http?.statusCode == 200 && body == "ok\n"
            let detail = ok ? "200 ok" : "got status=\(http?.statusCode ?? -1)"
            return (ok, detail)
        } catch {
            return (false, "\(error)")
        }
    }

    private func emit(_ results: [CheckResult]) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results),
                let text = String(data: data, encoding: .utf8)
            {
                print(text)
            }
        } else {
            for r in results {
                print("[\(r.severity.rawValue)]  \(r.name)  — \(r.detail)")
            }
        }
    }
}
