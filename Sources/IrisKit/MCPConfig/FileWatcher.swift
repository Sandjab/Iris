import CoreServices
import Foundation

/// Watches a single file for modifications using FSEventStream on the
/// containing directory (with filename filter). Coalesces bursts via a
/// configurable debounce window. Designed for `iris mcp wrap --watch`.
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let parentDir: String
    private let filename: String
    private let debounce: Duration
    private let queue: DispatchQueue

    // Mutable state — guarded by `queue` (serial).
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Void>.Continuation?
    private var debounceTask: Task<Void, Never>?
    private var stopped: Bool = false

    public init(path: String, debounce: Duration = .milliseconds(500)) {
        self.path = path
        self.parentDir = (path as NSString).deletingLastPathComponent
        self.filename = (path as NSString).lastPathComponent
        self.debounce = debounce
        self.queue = DispatchQueue(label: "io.iris.filewatcher.\(UUID().uuidString)")
    }

    /// Returns an AsyncStream that yields `()` per debounced burst of events
    /// on the target file. Calling `events()` more than once on the same
    /// watcher returns a fresh stream but only the latest subscriber receives
    /// events.
    public func events() -> AsyncStream<Void> {
        AsyncStream<Void> { continuation in
            self.queue.async {
                self.continuation = continuation
                self.startStreamLocked()
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.debounceTask?.cancel()
            self.debounceTask = nil
            if let s = self.stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                self.stream = nil
            }
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    // MARK: - Private — must be called on `queue`

    private func startStreamLocked() {
        // Implementation in Task 9.
    }
}
