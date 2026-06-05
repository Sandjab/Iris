import IrisKit

/// Seam over the (GUI-blocking, non-testable) trust-store mutation so AppModel's
/// install/uninstall orchestration is unit-testable with a fake.
public protocol CATrustInstalling: Sendable {
    func install(pemPath: String) throws
    func uninstall(pemPath: String) throws
}

/// Production impl: shells out via IrisKit's `CATrustStore` (`/usr/bin/security`,
/// presents the auth panel). Smoke-tested, not unit-tested.
public struct SystemCATrustInstaller: CATrustInstalling {
    public init() {}
    public func install(pemPath: String) throws { try CATrustStore.install(pemPath: pemPath) }
    public func uninstall(pemPath: String) throws { try CATrustStore.uninstall(pemPath: pemPath) }
}
