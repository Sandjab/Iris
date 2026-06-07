import Foundation

@testable import IrisAppCore

final class FakeShellConfigurator: ShellConfiguring, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = false
    var shouldThrow: Error?

    var installed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _installed
    }

    func install() throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _installed = true
        lock.unlock()
    }

    func uninstall() throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _installed = false
        lock.unlock()
    }

    func isInstalled() -> Bool { installed }
}
