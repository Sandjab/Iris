import ArgumentParser
import Crypto
import Foundation
import IrisKit
import Logging

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Patch MCP server config files (wrap/unwrap).",
        subcommands: [Wrap.self, Unwrap.self]
    )

    // MARK: - Wrap

    struct Wrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wrap",
            abstract: "Add proxy/CA env vars to MCP server config (JSON only)."
        )

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Path to .mcp.json / claude.json / claude_desktop_config.json")
        var path: String

        @Flag(name: .customLong("dry-run"), help: "Print diff without writing.")
        var dryRun: Bool = false

        @Flag(name: .customLong("json"), help: "Emit JSON summary.")
        var json: Bool = false

        @Flag(name: .customLong("watch"), help: "Re-patch on every file edit (single-file, long-running).")
        var watch: Bool = false

        @Option(name: .customLong("log-level"), help: "Log level for --watch (debug|info|warn|error).")
        var logLevel: String = "info"

        mutating func run() async throws {
            let expanded = (path as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expanded)

            if watch && dryRun {
                FileHandle.standardError.write(
                    Data("error: --watch and --dry-run are mutually exclusive\n".utf8)
                )
                throw ExitCode(64)
            }
            if watch {
                try await runWatch(path: expanded)
                return
            }

            // Anti-foot-gun: refuse to wrap a backup file
            if fileURL.lastPathComponent.hasSuffix(".iris.bak") {
                FileHandle.standardError.write(
                    Data("refusing to wrap a .iris.bak file: \(expanded)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Get broker listen + CA path from daemon (exits 2 if daemon down)
            let (brokerListen, caPath) = try await withAdminClient(connection) { client in
                let cfg = try await client.call(.configGet, returning: Config.self)
                let ca = try await client.call(.caExportPath, returning: CAExportPathResult.self)
                return (cfg.broker.listen, ca.path)
            }

            // Read source file
            let rawData: Data
            do {
                rawData = try Data(contentsOf: fileURL)
            } catch {
                FileHandle.standardError.write(Data("\(expanded): \(error)\n".utf8))
                throw ExitCode(IrisExitCode.logicError)
            }

            guard let text = String(data: rawData, encoding: .utf8) else {
                FileHandle.standardError.write(Data("\(expanded): not UTF-8\n".utf8))
                throw ExitCode(IrisExitCode.logicError)
            }

            let original: OrderedJSONDocument
            do {
                original = try OrderedJSONDocument.parse(text, options: .jsonc)
            } catch {
                FileHandle.standardError.write(
                    Data("\(expanded): not valid JSON\n  \(error)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Refuse-write if comments are present. --dry-run is still allowed.
            if !original.commentPositions.isEmpty && !dryRun {
                let first = original.commentPositions[0]
                FileHandle.standardError.write(
                    Data(
                        "\(expanded): comments detected at L\(first.line):\(first.column) — remove them manually or use --dry-run to see the diff\n"
                            .utf8
                    )
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            let originalSerialized = OrderedJSONDocument.serialize(original)

            let (patched, summary) = try MCPPatcher.patch(
                document: original,
                brokerListen: brokerListen,
                caPemPath: caPath
            )
            let patchedSerialized = OrderedJSONDocument.serialize(patched)

            // Already compliant — nothing to do
            if patchedSerialized == originalSerialized {
                emitOutcome("already compliant: \(expanded)", summary: summary)
                return
            }

            // Dry-run — show diff, no writes
            if dryRun {
                emitDiff(original: originalSerialized, patched: patchedSerialized, summary: summary)
                return
            }

            // Write backup atomically (overwrite any previous backup)
            let backupURL = fileURL.appendingPathExtension("iris.bak")
            do {
                try rawData.write(to: backupURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("backup write failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }

            guard let patchedData = patchedSerialized.data(using: .utf8) else {
                FileHandle.standardError.write(
                    Data("failed to encode patched output as UTF-8\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Sanity-validate the patched output before overwriting
            guard
                (try? JSONSerialization.jsonObject(
                    with: patchedData,
                    options: [.allowFragments]
                )) != nil
            else {
                FileHandle.standardError.write(
                    Data("patched output failed JSON validation; aborting\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            do {
                try patchedData.write(to: fileURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }

            emitOutcome("patched: \(expanded) (backup at \(backupURL.path))", summary: summary)
        }

        private func emitOutcome(_ message: String, summary: MCPPatcher.Summary) {
            if json {
                let payload = SummaryPayload(
                    patched: summary.patched,
                    alreadyCompliant: summary.alreadyCompliant,
                    skippedHttpSse: summary.skippedHttpSse,
                    errors: 0
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(payload),
                    let text = String(data: data, encoding: .utf8)
                {
                    print(text)
                }
            } else {
                print(message)
            }
        }

        private func emitDiff(original: String, patched: String, summary: MCPPatcher.Summary) {
            if json {
                emitOutcome("dry-run", summary: summary)
                return
            }
            print("--- original")
            print("+++ patched")
            print(
                "(summary: patched=\(summary.patched), already_compliant=\(summary.alreadyCompliant), skipped_http_sse=\(summary.skippedHttpSse))"
            )
            print("")
            print("--- ORIGINAL ---")
            print(original)
            print("--- PATCHED ---")
            print(patched)
        }

        private func runWatch(path: String) async throws {
            let fileURL = URL(fileURLWithPath: path)

            // Anti-foot-gun (same as one-shot)
            if fileURL.lastPathComponent.hasSuffix(".iris.bak") {
                FileHandle.standardError.write(
                    Data("refusing to watch a .iris.bak file: \(path)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Path must exist + readable at startup (decision §2.3 — fatal at start)
            guard FileManager.default.isReadableFile(atPath: path) else {
                FileHandle.standardError.write(
                    Data("no such file or unreadable: \(path)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Initial daemon fetch — exit 2 if down (cohérence avec autres sous-commandes)
            let (brokerListen, caPath) = try await withAdminClient(connection) { client in
                let cfg = try await client.call(.configGet, returning: Config.self)
                let ca = try await client.call(.caExportPath, returning: CAExportPathResult.self)
                return (cfg.broker.listen, ca.path)
            }

            // Setup logging
            let logger = Logger(label: "iris.watch")

            // State
            var lastWrittenHash: Data? = nil

            // Initial cycle (Task 14 implements the actual cycle body)
            try await runOneCycle(
                fileURL: fileURL,
                brokerListen: brokerListen,
                caPath: caPath,
                lastWrittenHash: &lastWrittenHash,
                logger: logger
            )

            logger.info("started, watching \(path)")

            // Watch loop (Task 14 wires FileWatcher in)
            // For now, exit after the initial cycle so the missing-path test passes.
        }

        private func runOneCycle(
            fileURL: URL,
            brokerListen: String,
            caPath: String,
            lastWrittenHash: inout Data?,
            logger: Logger
        ) async throws {
            // Implemented in Task 14.
        }
    }

    // MARK: - Unwrap

    struct Unwrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unwrap",
            abstract: "Restore the file from its .iris.bak backup."
        )

        @Argument(help: "Path to the file that was previously wrapped.")
        var path: String

        @Flag(name: .customLong("json"), help: "Emit JSON result.")
        var json: Bool = false

        mutating func run() async throws {
            let expanded = (path as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expanded)
            let backupURL = fileURL.appendingPathExtension("iris.bak")

            // Sanity: backup must exist, be readable, and parse as JSON
            guard let backupData = try? Data(contentsOf: backupURL) else {
                FileHandle.standardError.write(
                    Data("no backup found or readable at \(backupURL.path)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }
            guard
                (try? JSONSerialization.jsonObject(
                    with: backupData,
                    options: [.allowFragments]
                )) != nil
            else {
                FileHandle.standardError.write(
                    Data("backup is not valid JSON: \(backupURL.path)\n".utf8)
                )
                throw ExitCode(IrisExitCode.logicError)
            }

            // Atomic move: replaceItemAt moves backupURL into fileURL and removes the backup.
            do {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: backupURL)
            } catch {
                FileHandle.standardError.write(Data("restore failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }

            if json {
                let dict: [String: Any] = ["ok": true, "restored": expanded]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                    let jsonString = String(data: data, encoding: .utf8)
                {
                    print(jsonString)
                }
            } else {
                print("restored \(expanded)")
            }
        }
    }
}

// MARK: - Private types

private struct SummaryPayload: Encodable {
    let patched: Int
    let alreadyCompliant: Int
    let skippedHttpSse: Int
    let errors: Int

    enum CodingKeys: String, CodingKey {
        case patched
        case alreadyCompliant = "already_compliant"
        case skippedHttpSse = "skipped_http_sse"
        case errors
    }
}
