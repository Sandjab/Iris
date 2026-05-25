import Darwin
import Foundation

/// Installs a one-shot SIGINT handler that invokes the provided callback
/// asynchronously. After firing, restores `SIG_DFL` so a subsequent
/// Ctrl-C terminates immediately ("press Ctrl-C twice to force quit").
enum SignalHandling {
    static func onSIGINTOnce(_ callback: @escaping @Sendable () -> Void) {
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
    }
}

private final class SignalBox: @unchecked Sendable {
    let callback: @Sendable () -> Void
    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}

private nonisolated(unsafe) var sigintBox: SignalBox?
