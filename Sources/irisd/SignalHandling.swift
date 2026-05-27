import Darwin
import Foundation

// MARK: - SIGHUP support for irisd

/// An opaque token that keeps a signal handler installed for its lifetime.
/// Drop (or let deinit) to restore the default signal disposition.
final class IrisdSignalToken: @unchecked Sendable {
    private let cleanup: @Sendable () -> Void

    init(cleanup: @escaping @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    deinit { cleanup() }
}

/// Installs a repeating SIGHUP handler that invokes `handler` on every signal
/// (auto-rearming via DispatchSource). Returns a token whose lifetime controls
/// the handler; drop the token to restore the default SIGHUP disposition.
func installSIGHUP(_ handler: @escaping @Sendable () -> Void) -> IrisdSignalToken {
    let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global(qos: .utility))
    source.setEventHandler { handler() }
    source.resume()
    // Tell the kernel that DispatchSource owns SIGHUP so the default
    // terminate-process disposition does not fire alongside the handler.
    signal(SIGHUP, SIG_IGN)
    return IrisdSignalToken {
        source.cancel()
        signal(SIGHUP, SIG_DFL)
    }
}
