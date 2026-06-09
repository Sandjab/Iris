import Foundation
import IrisKit

/// Result of restoring all wrapped MCP config files.
public struct MCPUnwrapReport: Sendable, Equatable {
    /// Paths successfully restored.
    public var restored: [String]
    /// Paths that were listed but could not be restored (missing file/backup).
    public var skipped: [String]
    public init(restored: [String] = [], skipped: [String] = []) {
        self.restored = restored
        self.skipped = skipped
    }
}

/// Seam over the wrapped-paths registry + `MCPPatcher.unwrap`. Production:
/// `SystemMCPUnwrapper`. Tests: `FakeMCPUnwrapper`. Mirrors the seam pattern of
/// `CATrustInstalling` / `ShellConfiguring`.
public protocol MCPUnwrapping: Sendable {
    func unwrapAll() throws -> MCPUnwrapReport
}

public struct SystemMCPUnwrapper: MCPUnwrapping {
    private let registry: WrappedPathsRegistry

    public init(registry: WrappedPathsRegistry? = nil) throws {
        if let registry {
            self.registry = registry
        } else {
            self.registry = WrappedPathsRegistry(manifestURL: try WrappedPathsRegistry.defaultManifestURL())
        }
    }

    public func unwrapAll() throws -> MCPUnwrapReport {
        var report = MCPUnwrapReport()
        for path in try registry.list() {
            do {
                try MCPPatcher.unwrap(path: path)
                try? registry.remove(path)
                report.restored.append(path)
            } catch {
                // Stale entry (file or backup gone) — skip, never fatal.
                try? registry.remove(path)
                report.skipped.append(path)
            }
        }
        return report
    }
}
