import Foundation

@testable import IrisAppCore

final class FakeCATrustInstaller: CATrustInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var installedPath: String?
    private(set) var uninstalledPath: String?
    var shouldThrow: Error?

    func install(pemPath: String) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        installedPath = pemPath
        lock.unlock()
    }

    func uninstall(pemPath: String) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        uninstalledPath = pemPath
        lock.unlock()
    }
}
