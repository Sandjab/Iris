import Foundation

/// Reads NDJSON from a file descriptor (a plugin's stdout pipe) without blocking
/// a Swift Concurrency thread: a `DispatchSource` read source fires on its own
/// queue, drains the fd non-blockingly, and splits on `\n`. Each complete line
/// is delivered via `onLine`; end-of-stream via `onEOF`.
///
/// The buffer is confined to `queue` (the source serializes its handler), so the
/// `@unchecked Sendable` conformance is sound: no field is touched concurrently.
final class PluginLineReader: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let onLine: @Sendable (String) -> Void
    private let onEOF: @Sendable () -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var finished = false

    init(
        fileDescriptor: Int32,
        onLine: @escaping @Sendable (String) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.onLine = onLine
        self.onEOF = onEOF
        self.queue = DispatchQueue(label: "io.iris.plugin.reader")
    }

    deinit {
        stop()
    }

    func start() {
        // Non-blocking so reads inside the handler never stall the queue.
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source
        source.resume()
    }

    func stop() {
        queue.sync {
            guard !finished else { return }
            finished = true
            source?.cancel()
            source = nil
        }
    }

    private func drain() {
        guard !finished else { return }
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let n = scratch.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: scratch[0..<n])
                emitCompleteLines()
            } else if n == 0 {
                // EOF.
                finished = true
                source?.cancel()
                source = nil
                onEOF()
                return
            } else {
                // n < 0: EAGAIN/EWOULDBLOCK means "drained for now"; anything else
                // ends the stream.
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finished = true
                source?.cancel()
                source = nil
                onEOF()
                return
            }
        }
    }

    private func emitCompleteLines() {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            let line = String(decoding: lineData, as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...index)
            onLine(line)
        }
    }
}
