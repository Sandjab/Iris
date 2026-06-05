import ArgumentParser
import Foundation
import IrisKit

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Query daemon events (one-shot or --follow)."
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .customLong("since"), help: "Lower bound: ISO 8601 or relative (5m, 1h, 1d).")
    var since: String?

    @Option(name: .customLong("until"), help: "Upper bound: ISO 8601 or relative.")
    var until: String?

    @Option(name: .customLong("limit"), help: "Max events to return (one-shot only).")
    var limit: Int?

    @Option(
        name: .customLong("kind"),
        help:
            "Comma-separated event kinds (substituted, passThrough, noMatch, exfilBlocked, error, systemAlert)."
    )
    var kindRaw: String = ""

    @Option(name: .customLong("host"), help: "Filter by host.")
    var host: String?

    @Flag(name: .customLong("follow"), help: "Stream events via SSE until SIGINT.")
    var follow: Bool = false

    @Flag(name: .customLong("json"), help: "Emit JSON (ndjson in --follow mode).")
    var json: Bool = false

    mutating func validate() throws {
        if follow && (since != nil || until != nil || limit != nil) {
            throw ValidationError("--follow is incompatible with --since/--until/--limit")
        }
    }

    mutating func run() async throws {
        let kinds: [Event.Kind] =
            try kindRaw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .map { raw in
                guard let k = Event.Kind(rawValue: raw) else {
                    throw ValidationError("unknown event kind: \(raw)")
                }
                return k
            }

        if follow {
            try await runFollow(kinds: kinds)
        } else {
            try await runOneShot(kinds: kinds)
        }
    }

    // MARK: - One-shot

    private func runOneShot(kinds: [Event.Kind]) async throws {
        let now = Date()
        let sinceDate = try since.map { try RelativeTime.parse($0, relativeTo: now) }
        let untilDate = try until.map { try RelativeTime.parse($0, relativeTo: now) }

        let events = try await withAdminClient(connection) { client in
            try await client.call(
                .eventsQuery,
                params: EventsQueryParams(
                    since: sinceDate,
                    until: untilDate,
                    limit: limit,
                    kind: kinds.isEmpty ? nil : kinds,
                    host: host
                ),
                returning: [Event].self
            )
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            if events.isEmpty {
                print("no events")
            } else {
                for event in events {
                    print(formatEvent(event))
                }
            }
        }
    }

    // MARK: - Follow (SSE)

    private func runFollow(kinds: [Event.Kind]) async throws {
        // Resolve events_listen from daemon config (e.g. "127.0.0.1:8899").
        let eventsListen = try await withAdminClient(connection) { client in
            let cfg = try await client.call(.configGet, returning: Config.self)
            return cfg.broker.eventsListen
        }

        // Parse "host:port" from the listen address.
        let (eventsHost, eventsPort) = try parseHostPort(eventsListen)
        let client = EventsClient(host: eventsHost, port: eventsPort)

        // Run the streaming task; cancel it on SIGINT.
        let streamTask = Task {
            try await streamEvents(from: client, kinds: kinds)
        }

        let sigintToken = SignalHandling.onSIGINTOnce {
            streamTask.cancel()
        }

        do {
            defer { withExtendedLifetime(sigintToken) {} }
            try await streamTask.value
        } catch is CancellationError {
            // clean exit on SIGINT — no error message needed
        } catch {
            FileHandle.standardError.write(Data("stream disconnected: \(error)\n".utf8))
            throw ExitCode(IrisExitCode.ioError)
        }
    }

    private func streamEvents(from client: EventsClient, kinds: [Event.Kind]) async throws {
        let kindSet = Set(kinds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let stream = try await client.subscribe(
            since: nil,
            kinds: kindSet.isEmpty ? nil : Array(kindSet),
            host: host
        )

        for try await item in stream {
            try Task.checkCancellation()
            guard case .event(let event) = item else { continue }
            if !kindSet.isEmpty && !kindSet.contains(event.kind) { continue }
            if json {
                if let data = try? encoder.encode(event),
                    let line = String(data: data, encoding: .utf8)
                {
                    print(line)
                }
            } else {
                print(formatEvent(event))
            }
        }
    }

    // MARK: - Helpers

    private func parseHostPort(_ listenAddress: String) throws -> (String, Int) {
        // Expected format: "host:port" where host may be an IPv4 address.
        guard let colonIndex = listenAddress.lastIndex(of: ":") else {
            throw ValidationError("daemon events_listen has unexpected format: \(listenAddress)")
        }
        let host = String(listenAddress[..<colonIndex])
        let portString = String(listenAddress[listenAddress.index(after: colonIndex)...])
        guard let port = Int(portString), port > 0, port <= 65535 else {
            throw ValidationError("daemon events_listen has invalid port: \(portString)")
        }
        return (host, port)
    }

    private func formatEvent(_ event: Event) -> String {
        let iso = ISO8601DateFormatter().string(from: event.timestamp)
        let dur = event.durationMs.map { "\($0)ms" } ?? "-"
        let subs = event.substitutedSecrets.isEmpty ? "-" : event.substitutedSecrets.joined(separator: ",")
        return "\(iso)  \(event.kind.rawValue)  \(event.host)  \(event.method) \(event.path)  sub=\(subs) dur=\(dur)"
    }
}
