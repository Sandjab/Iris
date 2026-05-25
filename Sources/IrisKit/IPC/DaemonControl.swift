import Foundation

/// Thin protocol the admin dispatcher uses to read and mutate live daemon
/// state without depending on the concrete `ProxyServer`. Lets us mock the
/// daemon in dispatcher unit tests and keeps the IPC layer decoupled from
/// the proxy.
public protocol DaemonControl: Sendable {
    /// Process id of the daemon (typically `getpid()` of the host process).
    var processID: Int32 { get }
    /// Wall-clock time at which the daemon started serving requests.
    var startedAt: Date { get }
    /// Version string surfaced by `daemon.status`.
    var version: String { get }

    var isPaused: Bool { get }
    func setPaused(_ paused: Bool)
}

/// Trivial in-memory implementation backed by an immutable triple + an
/// atomic-ish flag. The flag is wired through `NIOLockedValueBox` upstream
/// in `ProxyServer`; here we just take a closure to read and write it.
public struct InProcessDaemonControl: DaemonControl {
    public let processID: Int32
    public let startedAt: Date
    public let version: String

    private let read: @Sendable () -> Bool
    private let write: @Sendable (Bool) -> Void

    public init(
        processID: Int32 = getpid(),
        startedAt: Date = Date(),
        version: String = DaemonVersion.current,
        readPaused: @escaping @Sendable () -> Bool,
        writePaused: @escaping @Sendable (Bool) -> Void
    ) {
        self.processID = processID
        self.startedAt = startedAt
        self.version = version
        self.read = readPaused
        self.write = writePaused
    }

    public var isPaused: Bool { read() }
    public func setPaused(_ paused: Bool) { write(paused) }
}
