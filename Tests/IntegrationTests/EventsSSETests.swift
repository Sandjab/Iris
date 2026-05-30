import Foundation
import IrisKit
import NIO
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

final class EventsSSETests: XCTestCase {

    private static let connectionWarmupBudget: TimeInterval = 3.0

    // MARK: - Helpers

    private func waitForSubscriber(
        bus: EventsBus,
        expected: Int = 1,
        deadline: TimeInterval = EventsSSETests.connectionWarmupBudget
    ) async throws {
        let stop = Date().addingTimeInterval(deadline)
        while Date() < stop {
            let count = await bus.subscriberCount
            if count >= expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let actual = await bus.subscriberCount
        XCTFail("server never registered subscriber (count=\(actual))")
    }

    private func makeEvent(host: String) -> Event {
        Event(
            id: UUID(),
            timestamp: Date(),
            kind: .substituted,
            host: host,
            method: "POST",
            path: "/v1/messages",
            statusCode: 200,
            durationMs: 12,
            substitutedSecrets: ["k"]
        )
    }

    // MARK: - Refusing non-loopback

    func testServerRefusesNonLoopbackHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bus = EventsBus()
        let ring = EventRing(capacity: 8, bus: bus)
        let server = EventsServer(
            listenHost: "0.0.0.0",
            listenPort: 0,
            bus: bus,
            eventRing: ring,
            group: group
        )
        do {
            _ = try await server.start()
            XCTFail("expected refusingNonLoopbackHost")
        } catch let error as EventsServerError {
            switch error {
            case .refusingNonLoopbackHost(let host):
                XCTAssertEqual(host, "0.0.0.0")
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Live event streaming (raw NIO client)

    /// This test uses a raw NIO HTTP client (not `EventsClient`) to assert on
    /// the exact bytes the server writes. Historically `EventsClient` was
    /// URLSession-based and its `bytes.lines` retained a frame's terminating
    /// blank line until a later byte arrived, so it could not surface an
    /// isolated event in real time. `EventsClient` is now swift-nio-based and
    /// is exercised directly by `testEventsClientReceivesSingleIsolatedEvent`.
    func testServerStreamsEventBytesAfterRingAppend() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bus = EventsBus()
        let ring = EventRing(capacity: 32, bus: bus)
        let server = EventsServer(
            listenHost: "127.0.0.1",
            listenPort: 0,
            bus: bus,
            eventRing: ring,
            group: group
        )
        let address = try await server.start()
        defer { Task { try? await server.stop() } }
        let port = try XCTUnwrap(address.port)

        let collector = try await connectAndCollect(port: port, query: nil, group: group)
        try await waitForSubscriber(bus: bus)

        let event = makeEvent(host: "live.example.com")
        await ring.append(event)

        let buffer = try await collector.waitForBytes(
            containing: "event: substituted",
            timeout: 5
        )
        XCTAssertTrue(buffer.contains("event: substituted"), "missing event line: \(buffer)")
        XCTAssertTrue(buffer.contains("live.example.com"), "missing host: \(buffer)")
        await collector.close()

        try await server.stop()
    }

    func testServerOmitsEventsFailingHostFilter() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bus = EventsBus()
        let ring = EventRing(capacity: 32, bus: bus)
        let server = EventsServer(
            listenHost: "127.0.0.1",
            listenPort: 0,
            bus: bus,
            eventRing: ring,
            group: group
        )
        let address = try await server.start()
        defer { Task { try? await server.stop() } }
        let port = try XCTUnwrap(address.port)

        let collector = try await connectAndCollect(
            port: port,
            query: "host=wanted.example.com",
            group: group
        )
        try await waitForSubscriber(bus: bus)

        await ring.append(makeEvent(host: "other.example.com"))
        await ring.append(makeEvent(host: "wanted.example.com"))

        let buffer = try await collector.waitForBytes(
            containing: "wanted.example.com",
            timeout: 5
        )
        XCTAssertFalse(
            buffer.contains("other.example.com"),
            "filtered event leaked into stream: \(buffer)"
        )
        await collector.close()

        try await server.stop()
    }

    // MARK: - EventsClient end-to-end (real client + real server)

    /// Regression test for the SSE live bug. The old URLSession-based
    /// `EventsClient` consumed the body via `bytes.lines`, an `AsyncSequence`
    /// that retains the blank line terminating an SSE frame until a *later*
    /// byte arrives. An isolated event therefore never materialized in real
    /// time — only when a second event (or the 15 s heartbeat) pushed the
    /// buffered blank line through. Here we publish EXACTLY ONE event and keep
    /// the stream open: it MUST arrive within the deadline. Encodes the intent
    /// (Rule 9): a single live event must surface immediately, not wait for the
    /// next frame.
    func testEventsClientReceivesSingleIsolatedEvent() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bus = EventsBus()
        let ring = EventRing(capacity: 32, bus: bus)
        let server = EventsServer(
            listenHost: "127.0.0.1",
            listenPort: 0,
            bus: bus,
            eventRing: ring,
            group: group
        )
        let address = try await server.start()
        let port = try XCTUnwrap(address.port)

        // Real client over the shared group (the test owns the ELG lifetime).
        let client = EventsClient(host: "127.0.0.1", port: port, group: group)
        let stream = try await client.subscribe(since: nil)

        // Drive the stream in a child task; capture the first `.event`,
        // ignoring the priming `: connected` heartbeat (.ping).
        let received = Task { () -> Event? in
            for try await item in stream {
                if case .event(let event) = item { return event }
            }
            return nil
        }

        try await waitForSubscriber(bus: bus)
        let event = makeEvent(host: "isolated.example.com")
        await ring.append(event)  // EXACTLY ONE event; nothing else published

        let got = try await withThrowingTaskGroup(of: Event?.self) { taskGroup -> Event? in
            taskGroup.addTask { try await received.value }
            taskGroup.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s deadline
                return nil
            }
            let first = try await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return first
        }

        // Ordered async teardown BEFORE asserting: cancelling the consumer
        // closes the SSE channel (via onTermination), then we stop the server
        // and shut the group down with the non-blocking async API. Doing this
        // first means a failed assertion can never strand an open connection on
        // a blocking `syncShutdownGracefully`.
        received.cancel()
        try? await server.stop()
        try? await group.shutdownGracefully()

        let unwrapped = try XCTUnwrap(
            got,
            "EventsClient did not deliver the isolated event within 5s"
        )
        XCTAssertEqual(unwrapped.id, event.id)
        XCTAssertEqual(unwrapped.host, "isolated.example.com")
    }

    /// Locks the multi-line / multi-frame byte parsing in `drainLines`: each SSE
    /// frame is `event:`/`id:`/`data:` + a blank line (already several lines per
    /// `channelRead`), and back-to-back events advance the buffer's readerIndex
    /// across iterations. If the line-length math were wrong for anything past
    /// the first line, the second event would be garbled or never arrive. Both
    /// must surface, in order.
    func testEventsClientReceivesMultipleEvents() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bus = EventsBus()
        let ring = EventRing(capacity: 32, bus: bus)
        let server = EventsServer(
            listenHost: "127.0.0.1",
            listenPort: 0,
            bus: bus,
            eventRing: ring,
            group: group
        )
        let address = try await server.start()
        let port = try XCTUnwrap(address.port)

        let client = EventsClient(host: "127.0.0.1", port: port, group: group)
        let stream = try await client.subscribe(since: nil)

        let received = Task { () -> [Event] in
            var events: [Event] = []
            for try await item in stream {
                if case .event(let event) = item {
                    events.append(event)
                    if events.count == 2 { return events }
                }
            }
            return events
        }

        try await waitForSubscriber(bus: bus)
        let first = makeEvent(host: "first.example.com")
        let second = makeEvent(host: "second.example.com")
        await ring.append(first)
        await ring.append(second)

        let got = try await withThrowingTaskGroup(of: [Event]?.self) { taskGroup -> [Event]? in
            taskGroup.addTask { try await received.value }
            taskGroup.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s deadline
                return nil
            }
            let firstResult = try await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return firstResult
        }

        received.cancel()
        try? await server.stop()
        try? await group.shutdownGracefully()

        let events = try XCTUnwrap(got, "EventsClient did not deliver both events within 5s")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].host, "first.example.com")
        XCTAssertEqual(events[1].host, "second.example.com")
    }

    // MARK: - Raw NIO collector

    /// Opens an HTTP/1.1 connection to the SSE server, sends a `GET /events`
    /// request, and accumulates every byte the server writes into a single
    /// shared string buffer. `waitForBytes(containing:)` polls until the
    /// expected substring shows up or the deadline elapses.
    private func connectAndCollect(
        port: Int,
        query: String?,
        group: EventLoopGroup
    ) async throws -> SSEByteCollector {
        let collector = SSEByteCollector()
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.eventLoop.makeCompletedFuture(
                        withResultOf: {
                            try channel.pipeline.syncOperations.addHandler(
                                RawHTTPBodyCollector(buffer: collector.box)
                            )
                        }
                    )
                }
            }

        let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
        collector.attach(channel: channel)

        var uri = "/events"
        if let query = query { uri += "?" + query }
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
        head.headers.add(name: "Host", value: "127.0.0.1:\(port)")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Connection", value: "keep-alive")
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil))
        return collector
    }
}

// MARK: - Collector

final class SSEByteCollector: @unchecked Sendable {
    let box = NIOLockedValueBox<String>("")
    private var channel: Channel?

    func attach(channel: Channel) { self.channel = channel }

    func waitForBytes(containing needle: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = box.withLockedValue { $0 }
            if snapshot.contains(needle) { return snapshot }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return box.withLockedValue { $0 }
    }

    func close() async {
        if let channel = channel {
            try? await channel.close()
        }
    }
}

final class RawHTTPBodyCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let buffer: NIOLockedValueBox<String>

    init(buffer: NIOLockedValueBox<String>) { self.buffer = buffer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head:
            break
        case .body(var bytes):
            let text = bytes.readString(length: bytes.readableBytes) ?? ""
            buffer.withLockedValue { $0.append(text) }
        case .end:
            break
        }
    }
}
