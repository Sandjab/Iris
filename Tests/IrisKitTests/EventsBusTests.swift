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
        XCTAssertEqual(item, .event(event))
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
        let (id1, _) = await bus.subscribe()
        let (id2, _) = await bus.subscribe()
        count = await bus.subscriberCount
        XCTAssertEqual(count, 2)
        await bus.unsubscribe(id: id1)
        count = await bus.subscriberCount
        XCTAssertEqual(count, 1)
        await bus.unsubscribe(id: id2)
        count = await bus.subscriberCount
        XCTAssertEqual(count, 0)
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
        XCTAssertEqual(a, .event(event))
        XCTAssertEqual(b, .event(event))
    }

    func testBackpressureEmitsDroppedSentinelAndClosesStream() async {
        // Tiny queue forces the AsyncStream's bufferingNewest policy to
        // drop on the third yield with no consumer reads in between, which
        // is what the publisher detects to fire the sentinel.
        let bus = EventsBus(queueDepth: 2)
        let (_, stream) = await bus.subscribe()

        for index in 0..<6 {
            await bus.publish(Self.makeEvent(host: "h\(index)"))
        }

        var collected: [SSEItem] = []
        for await item in stream {
            collected.append(item)
        }

        // The stream must terminate (we drained it fully). The final item
        // is the dropped sentinel.
        guard case .dropped(let count) = collected.last else {
            return XCTFail("expected trailing .dropped sentinel, got \(collected)")
        }
        XCTAssertGreaterThan(count, 0)
    }

    func testEventRingAttachedBusReceivesAppendedEvents() async {
        let bus = EventsBus()
        let ring = EventRing(capacity: 8, bus: bus)
        let (_, stream) = await bus.subscribe()
        let event = Self.makeEvent(host: "ring.example.com")
        await ring.append(event)

        var iterator = stream.makeAsyncIterator()
        let item = await iterator.next()
        XCTAssertEqual(item, .event(event))
    }
}
