import Foundation

/// Records the absolute paths of MCP config files that `iris mcp wrap` has
/// patched, so the uninstall flow can restore every one of them. The manifest
/// is a JSON array of absolute paths, deduplicated, insertion-ordered.
///
/// Lives at `~/Library/Application Support/iris/wrapped-paths.json` by default;
/// tests inject a temporary URL.
public struct WrappedPathsRegistry: Sendable {
    private let manifestURL: URL

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    /// Default location, alongside the daemon's other support files.
    public static func defaultManifestURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return
            support
            .appendingPathComponent("iris", isDirectory: true)
            .appendingPathComponent("wrapped-paths.json")
    }

    public func list() throws -> [String] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public func add(_ path: String) throws {
        var paths = try list()
        guard !paths.contains(path) else { return }
        paths.append(path)
        try write(paths)
    }

    public func remove(_ path: String) throws {
        var paths = try list()
        paths.removeAll { $0 == path }
        try write(paths)
    }

    private func write(_ paths: [String]) throws {
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(paths).write(to: manifestURL, options: .atomic)
    }
}
