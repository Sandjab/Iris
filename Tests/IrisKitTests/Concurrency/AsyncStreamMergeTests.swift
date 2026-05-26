import XCTest
@testable import IrisKit

final class AsyncStreamMergeTests: XCTestCase {
    func testMergesItemsFromBothStreams() async {
        let s1 = AsyncStream<Int> { cont in
            Task {
                cont.yield(1)
                try? await Task.sleep(for: .milliseconds(50))
                cont.yield(3)
                cont.finish()
            }
        }
        let s2 = AsyncStream<Int> { cont in
            Task {
                try? await Task.sleep(for: .milliseconds(25))
                cont.yield(2)
                cont.finish()
            }
        }
        var received: [Int] = []
        for await item in mergeAsyncStreams(s1, s2) {
            received.append(item)
        }
        XCTAssertEqual(Set(received), [1, 2, 3])
    }

    func testTerminatesWhenBothSourcesFinish() async {
        let empty1 = AsyncStream<Int> { $0.finish() }
        let empty2 = AsyncStream<Int> { $0.finish() }
        var count = 0
        for await _ in mergeAsyncStreams(empty1, empty2) { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
