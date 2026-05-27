import Darwin
import Foundation

/// Installs a one-shot SIGINT handler that invokes the provided callback
/// asynchronously. Returns a token that, when held, keeps the handler
/// armed. Drop the token (or let it deinit) to restore default SIGINT
/// behavior — prevents handler residue and reference cycles when the
/// caller's loop finishes normally instead of via Ctrl-C.
enum SignalHandling {
    /// Installs a repeating SIGHUP handler that invokes the provided callback
    /// asynchronously on every signal. The handler re-arms itself automatically.
    /// Returns a token that, when held, keeps the handler installed. Drop the
    /// token (or let it deinit) to restore the default SIGHUP disposition.
    static func installSIGHUP(_ handler: @escaping @Sendable () -> Void) -> SignalToken {
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global(qos: .utility))
        source.setEventHandler { handler() }
        source.resume()
        // Tell the kernel that DispatchSource owns SIGHUP; without this the
        // default disposition (terminate) would still fire alongside the handler.
        signal(SIGHUP, SIG_IGN)
        return SignalToken {
            source.cancel()
            signal(SIGHUP, SIG_DFL)
        }
    }

    static func onSIGINTOnce(_ callback: @escaping @Sendable () -> Void) -> SignalToken {
        let box = SignalBox(callback: callback)
        sigintBox = box
        signal(SIGINT) { _ in
            let box = sigintBox
            sigintBox = nil
            signal(SIGINT, SIG_DFL)
            if let box = box {
                DispatchQueue.global(qos: .userInitiated).async {
                    box.callback()
                }
            }
        }
        return SignalToken {
            if sigintBox === box {
                sigintBox = nil
                signal(SIGINT, SIG_DFL)
            }
        }
    }
}

final class SignalToken: @unchecked Sendable {
    private let cleanup: @Sendable () -> Void

    init(cleanup: @escaping @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    deinit {
        cleanup()
    }
}

private final class SignalBox: @unchecked Sendable {
    let callback: @Sendable () -> Void
    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}

private nonisolated(unsafe) var sigintBox: SignalBox?
