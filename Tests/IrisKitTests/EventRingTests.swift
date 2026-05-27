import XCTest

@testable import IrisKit

final class EventRingTests: XCTestCase {
    func testAppendStoresEvent() async throws {
        let ring = EventRing(capacity: 16)
        let event = Self.makeEvent(host: "h1")
        await ring.append(event)
        let stored = await ring.all
        XCTAssertEqual(stored, [event])
    }

    func testAppendPreservesInsertionOrder() async throws {
        let ring = EventRing(capacity: 16)
        let events = (0..<5).map { Self.makeEvent(host: "h\($0)") }
        for event in events { await ring.append(event) }
        let stored = await ring.all
        XCTAssertEqual(stored.map(\.host), ["h0", "h1", "h2", "h3", "h4"])
    }

    func testRingEvictsOldestWhenAtCapacity() async throws {
        let ring = EventRing(capacity: 3)
        for index in 0..<5 {
            await ring.append(Self.makeEvent(host: "h\(index)"))
        }
        let stored = await ring.all
        // First two appended events should have been evicted, only the last
        // three remain in FIFO order.
        XCTAssertEqual(stored.map(\.host), ["h2", "h3", "h4"])
    }

    func testRecentReturnsLastNInOrder() async throws {
        let ring = EventRing(capacity: 16)
        for index in 0..<5 {
            await ring.append(Self.makeEvent(host: "h\(index)"))
        }
        let recent = await ring.recent(3)
        XCTAssertEqual(recent.map(\.host), ["h2", "h3", "h4"])
    }

    func testRecentClampsToAvailableWhenAskedForMore() async throws {
        let ring = EventRing(capacity: 16)
        await ring.append(Self.makeEvent(host: "only"))
        let recent = await ring.recent(10)
        XCTAssertEqual(recent.map(\.host), ["only"])
    }

    func testRecentWithZeroOrNegativeReturnsEmpty() async throws {
        let ring = EventRing(capacity: 16)
        for index in 0..<3 {
            await ring.append(Self.makeEvent(host: "h\(index)"))
        }
        let zero = await ring.recent(0)
        let negative = await ring.recent(-5)
        XCTAssertEqual(zero, [])
        XCTAssertEqual(negative, [])
    }

    func testEventsSinceFiltersByTimestamp() async throws {
        let ring = EventRing(capacity: 16)
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for offset in 0..<5 {
            await ring.append(
                Self.makeEvent(host: "h\(offset)", timestamp: base.addingTimeInterval(Double(offset)))
            )
        }
        let cutoff = base.addingTimeInterval(2)
        let after = await ring.events(since: cutoff)
        XCTAssertEqual(after.map(\.host), ["h2", "h3", "h4"])
    }

    func testConcurrentAppendsAreAllRecorded() async throws {
        let ring = EventRing(capacity: 1_024)
        let total = 256
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<total {
                group.addTask {
                    await ring.append(Self.makeEvent(host: "h\(index)"))
                }
            }
        }
        let stored = await ring.all
        XCTAssertEqual(stored.count, total)
        // Insertion order across tasks is non-deterministic, but the set of
        // hosts must match exactly (no drops, no duplicates).
        let hosts = Set(stored.map(\.host))
        let expected = Set((0..<total).map { "h\($0)" })
        XCTAssertEqual(hosts, expected)
    }

    func testDefaultCapacityIs10000() async throws {
        // Pin the SPECS §19.3 contract: the default ring keeps the last
        // 10 000 events. We append a few past the boundary and verify the
        // oldest is gone but the boundary one survives.
        let ring = EventRing()
        for index in 0..<10_003 {
            await ring.append(Self.makeEvent(host: "h\(index)"))
        }
        let stored = await ring.all
        XCTAssertEqual(stored.count, 10_000)
        XCTAssertEqual(stored.first?.host, "h3")
        XCTAssertEqual(stored.last?.host, "h10002")
    }

    // MARK: - clear()

    func testClearEmptiesEntriesAndReturnsDeletedCount() async throws {
        let ring = EventRing(capacity: 100)
        for _ in 0..<5 {
            await ring.append(Self.makeEvent(host: "h1"))
        }
        let deleted = await ring.clear()
        XCTAssertEqual(deleted, 5)
        let remaining = await ring.recent(100)
        XCTAssertEqual(remaining.count, 0)
    }

    func testClearPreservesCumulativeTotals() async throws {
        let ring = EventRing(capacity: 100)
        for _ in 0..<3 {
            await ring.append(Self.makeEvent(host: "h1"))
        }
        _ = await ring.clear()
        let totalSubstituted = await ring.count(of: .substituted)
        XCTAssertEqual(totalSubstituted, 3, "totals must survive clear()")
    }

    func testClearOnEmptyRingReturnsZero() async throws {
        let ring = EventRing(capacity: 100)
        let deleted = await ring.clear()
        XCTAssertEqual(deleted, 0)
    }

    // MARK: - Helpers

    private static func makeEvent(
        host: String,
        timestamp: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> Event {
        Event(
            timestamp: timestamp,
            kind: .substituted,
            host: host,
            method: "POST",
            path: "/v1/messages"
        )
    }
}
