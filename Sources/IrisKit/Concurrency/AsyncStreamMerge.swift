import Foundation

/// Merges two `AsyncStream`s of the same element type into one. The merged
/// stream finishes after both sources finish. Order across sources is not
/// deterministic — items are yielded in the order they arrive.
///
/// Used by `iris mcp wrap --watch` to combine FSEvents-driven file events
/// and backoff retry ticks into a single loop.
public func mergeAsyncStreams<T: Sendable>(
    _ a: AsyncStream<T>,
    _ b: AsyncStream<T>
) -> AsyncStream<T> {
    AsyncStream<T> { continuation in
        let counter = MergeCounter()
        let taskA = Task {
            for await item in a {
                continuation.yield(item)
            }
            if await counter.finishOne() {
                continuation.finish()
            }
        }
        let taskB = Task {
            for await item in b {
                continuation.yield(item)
            }
            if await counter.finishOne() {
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in
            taskA.cancel()
            taskB.cancel()
        }
    }
}

private actor MergeCounter {
    private var finished = 0
    func finishOne() -> Bool {
        finished += 1
        return finished == 2
    }
}
