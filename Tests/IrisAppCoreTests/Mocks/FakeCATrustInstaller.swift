import Foundation

@testable import IrisAppCore

final class FakeCATrustInstaller: CATrustInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _installedPath: String?
    private var _uninstalledPath: String?
    var shouldThrow: Error?

    // Reads are lock-protected too: the writes happen on the detached task spawned by
    // AppModel, so reads from the test (main thread) must take the lock for the
    // @unchecked Sendable contract to hold unconditionally (TSAN-clean).
    var installedPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return _installedPath
    }

    var uninstalledPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return _uninstalledPath
    }

    func install(pemPath: String) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _installedPath = pemPath
        lock.unlock()
    }

    func uninstall(pemPath: String) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _uninstalledPath = pemPath
        lock.unlock()
    }
}
