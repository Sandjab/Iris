import Foundation

/// Locates executables produced by `swift build` so integration tests can
/// spawn them via `Process`. Resolves the directory that contains the
/// running `.xctest` bundle — SwiftPM places test bundles in the same
/// products directory as executables (`debug/` or `release/`).
enum ExecutableLocator {
    static func url(forProduct name: String) -> URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(name)
        }
        fatalError("XCTest bundle not found; cannot locate \(name)")
    }

    static var iris: URL { url(forProduct: "iris") }
    static var irisd: URL { url(forProduct: "irisd") }
    static var sandboxExec: URL { url(forProduct: "iris-sandbox-exec") }
}
