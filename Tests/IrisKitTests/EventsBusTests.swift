import XCTest

@testable import IrisKit

final class EventsBusTests: XCTestCase {

    private static func makeEvent(host: String = "api.example.com") -> Event {
        Event(
            timestamp: Date(),
            kind: .substituted,
            host: host,
            method: "POST",
            path: "/v1/messages"
        )
    }

    func testSubscribePublishDelivers() async {
        let bus = EventsBus()
        let (_, stream) = await bus.subscribe()
        let event = Self.makeEvent()
        await bus.publish(event)

        var iterator = stream.makeAsyncIterator()
        let item = await iterator.next()
        XCTAssertEqual(item, event)
    }

    func testUnsubscribeFinishesStream() async {
        let bus = EventsBus()
        let (id, stream) = await bus.subscribe()
        await bus.unsubscribe(id: id)

        var iterator = stream.makeAsyncIterator()
        let item = await iterator.next()
        XCTAssertNil(item)
    }

    func testSubscriberCountTracksLifecycle() async {
        let bus = EventsBus()
        var count = await bus.subscriberCount
        XCTAssertEqual(count, 0)
        // Streams must be held: `onTermination` fires the moment a stream
        // is deinitialised, which would unsubscribe before we ever sample
        // the count.
        let (id1, stream1) = await bus.subscribe()
        let (id2, stream2) = await bus.subscribe()
        count = await bus.subscriberCount
        XCTAssertEqual(count, 2)
        await bus.unsubscribe(id: id1)
        count = await bus.subscriberCount
        XCTAssertEqual(count, 1)
        await bus.unsubscribe(id: id2)
        count = await bus.subscriberCount
        XCTAssertEqual(count, 0)
        _ = stream1
        _ = stream2
    }

    func testMultipleSubscribersEachReceiveOnePublishedEvent() async {
        let bus = EventsBus()
        let (_, streamA) = await bus.subscribe()
        let (_, streamB) = await bus.subscribe()
        let event = Self.makeEvent()
        await bus.publish(event)

        var itA = streamA.makeAsyncIterator()
        var itB = streamB.makeAsyncIterator()
        let a = await itA.next()
        let b = await itB.next()
        XCTAssertEqual(a, event)
        XCTAssertEqual(b, event)
    }

    func testBufferingNewestEvictsOldestSilentlyBeyondQueueDepth() async {
        // Documents the Phase-3 behaviour after the Gemini-flagged
        // backpressure-sentinel removal: with `.bufferingNewest(N)` the
        // oldest items are dropped from the AsyncStream buffer to make
        // room for newer ones. There is no `event: dropped` sentinel
        // emitted — slow-consumer detection is a Phase 3.x follow-up
        // pending a `NIOAsyncWriter` migration.
        let bus = EventsBus(queueDepth: 2)
        let (_, stream) = await bus.subscribe()
        for index in 0..<5 {
            await bus.publish(Self.makeEvent(host: "h\(index)"))
        }

        // Read exactly two items: the newest two survive.
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.host, "h3")
        XCTAssertEqual(second?.host, "h4")
    }

    func testEventRingAttachedBusReceivesAppendedEvents() async {
        let bus = EventsBus()
        let ring = EventRing(capacity: 8, bus: bus)
        let (_, stream) = await bus.subscribe()
        let event = Self.makeEvent(host: "ring.example.com")
        await ring.append(event)

        var iterator = stream.makeAsyncIterator()
        let item = await iterator.next()
        XCTAssertEqual(item, event)
    }

    func testDroppingStreamTriggersOnTerminationCleanup() async throws {
        // Gemini-flagged memory leak: abruptly-disconnected subscribers used
        // to linger in the dictionary because the `.terminated` cleanup in
        // `publish()` only ran on the next event. We now register an
        // `onTermination` callback that unsubscribes eagerly. Verify by
        // dropping the stream and waiting for the callback to land.
        let bus = EventsBus()
        do {
            _ = await bus.subscribe()
            // Stream + continuation reference held only in this scope.
        }
        // Allow the runtime to run the AsyncStream deinit and the spawned
        // unsubscribe Task.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, await bus.subscriberCount > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let count = await bus.subscriberCount
        XCTAssertEqual(count, 0, "onTermination should have evicted the subscriber")
    }
}
