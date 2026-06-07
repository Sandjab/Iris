import IrisKit

/// Seam over the shell-profile mutation so AppModel's configure/unconfigure
/// orchestration is unit-testable with a fake. Mirrors `CATrustInstalling`.
public protocol ShellConfiguring: Sendable {
    func install() throws
    func uninstall() throws
    func isInstalled() -> Bool
}

/// Production impl: delegates to IrisKit's `ShellProfileConfigurator` (writes
/// `~/.zshrc`). Covered by manual smoke, not unit tests.
public struct SystemShellConfigurator: ShellConfiguring {
    public init() {}
    public func install() throws { try ShellProfileConfigurator.install() }
    public func uninstall() throws { try ShellProfileConfigurator.uninstall() }
    public func isInstalled() -> Bool { ShellProfileConfigurator.isInstalled() }
}
