import Foundation

// MARK: - Errors

public enum EventsClientError: Error, Equatable, LocalizedError {
    case invalidURL(String)
    case httpStatus(Int)
    case streamClosed
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid events URL: \(url)"
        case .httpStatus(let code): return "Events endpoint returned HTTP \(code)"
        case .streamClosed: return "Events stream closed by server"
        case .decodeFailed(let message): return "Failed to decode SSE event: \(message)"
        }
    }
}

// MARK: - Item

public enum EventsClientItem: Sendable, Equatable {
    case event(Event)
    case ping
}

// MARK: - Client

/// Minimal SSE consumer for the `/events` endpoint (SPECS §14). Uses
/// `URLSession.bytes(for:)` to stream the HTTP response body and parses
/// the standard `event:` / `id:` / `data:` SSE format.
public struct EventsClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(
        host: String = "127.0.0.1",
        port: Int,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        // URLComponents path/host parsing is overkill here: assemble the
        // loopback URL by string and force-unwrap with a precondition. If
        // the inputs are non-sensical the daemon would never have started.
        guard let url = URL(string: "http://\(host):\(port)/events") else {
            preconditionFailure("EventsClient cannot build URL from host=\(host) port=\(port)")
        }
        self.baseURL = url
        self.session = session
    }

    public func subscribe(
        since: Date? = nil,
        kinds: [Event.Kind]? = nil,
        host: String? = nil
    ) async throws -> AsyncThrowingStream<EventsClientItem, Error> {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []
        if let since = since {
            let formatter = ISO8601DateFormatter()
            queryItems.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        if let kinds = kinds, !kinds.isEmpty {
            queryItems.append(
                URLQueryItem(name: "kind", value: kinds.map(\.rawValue).joined(separator: ","))
            )
        }
        if let host = host {
            queryItems.append(URLQueryItem(name: "host", value: host))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw EventsClientError.invalidURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EventsClientError.httpStatus(http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let parserTask = Task {
                var current: SSEFrame = SSEFrame()
                do {
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Frame boundary: flush whatever we accumulated.
                            if let item = try Self.materialize(frame: current) {
                                continuation.yield(item)
                            }
                            current = SSEFrame()
                            continue
                        }
                        if line.hasPrefix(":") {
                            // SSE comment — used as heartbeat by the server.
                            continuation.yield(.ping)
                            continue
                        }
                        Self.absorb(line: line, into: &current)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in parserTask.cancel() }
        }
    }

    private struct SSEFrame {
        var eventName: String?
        var id: String?
        var data: String = ""
    }

    private static func absorb(line: String, into frame: inout SSEFrame) {
        // Each line is `field: value` or `field:value`.
        guard let colonIndex = line.firstIndex(of: ":") else { return }
        let field = String(line[..<colonIndex])
        var valueStart = line.index(after: colonIndex)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        let value = String(line[valueStart...])
        switch field {
        case "event": frame.eventName = value
        case "id": frame.id = value
        case "data":
            if !frame.data.isEmpty { frame.data.append("\n") }
            frame.data.append(value)
        default:
            break
        }
    }

    private static func materialize(frame: SSEFrame) throws -> EventsClientItem? {
        guard frame.eventName != nil else { return nil }
        guard let payloadData = frame.data.data(using: .utf8) else { return nil }
        do {
            let event = try JSONRPCCoder.makeDecoder().decode(Event.self, from: payloadData)
            return .event(event)
        } catch {
            throw EventsClientError.decodeFailed("\(error)")
        }
    }
}
