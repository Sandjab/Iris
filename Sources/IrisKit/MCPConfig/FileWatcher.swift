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
        // Resolve to an absolute path so FSEventStreamCreate gets a valid
        // directory even if the caller passed a relative path (where
        // NSString.deletingLastPathComponent would return "").
        let absolutePath = URL(fileURLWithPath: path).path
        self.path = absolutePath
        self.parentDir = (absolutePath as NSString).deletingLastPathComponent
        self.filename = (absolutePath as NSString).lastPathComponent
        self.debounce = debounce
        self.queue = DispatchQueue(label: "io.iris.filewatcher.\(UUID().uuidString)")
    }

    deinit {
        // Defensive cleanup if the caller forgets to call stop() before
        // releasing the watcher. FSEventStreamStop/Invalidate/Release are
        // documented as thread-safe. After Stop returns no further events
        // will be dispatched, so the callback cannot use-after-free `self`.
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        debounceTask?.cancel()
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
        guard !stopped, stream == nil else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
        let paths = [parentDir] as CFArray
        guard
            let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                { (_, info, _, paths, _, _) in
                    guard let info = info else { return }
                    let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                    let cfPaths = unsafeBitCast(paths, to: CFArray.self)
                    guard let pathsArr = cfPaths as? [String] else { return }
                    watcher.handleEvents(paths: pathsArr)
                },
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.0,
                flags
            )
        else {
            // FSEventStreamCreate failed (rare — usually invalid path or OOM).
            // Finish the continuation so the subscriber doesn't hang forever.
            continuation?.finish()
            continuation = nil
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            self.stream = s
        } else {
            FSEventStreamRelease(s)
            continuation?.finish()
            continuation = nil
        }
    }

    /// Called from FSEvents on `queue`. Filters to target filename and
    /// schedules a debounced emit.
    fileprivate func handleEvents(paths: [String]) {
        queue.async {
            guard !self.stopped else { return }
            // FSEvents emits absolute paths matching the watched dir; filter
            // by lastPathComponent to ignore writes to other files in the dir.
            let matches = paths.contains {
                ($0 as NSString).lastPathComponent == self.filename
            }
            guard matches else { return }
            self.scheduleDebouncedEmitLocked()
        }
    }

    private func scheduleDebouncedEmitLocked() {
        debounceTask?.cancel()
        let debounceCopy = self.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounceCopy)
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.continuation?.yield()
            }
        }
    }
}
