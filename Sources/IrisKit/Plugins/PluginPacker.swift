import Foundation

/// Assembles an installable plugin bundle from a *built* plugin source directory.
///
/// A Swift plugin's source tree references its binary through SwiftPM's
/// `.build/release/<tool>` symlink and carries the whole `.build/` tree — both
/// rejected by `PluginSourceValidator` (no symlinks; bounded size). `pack`
/// produces a clean bundle `{ plugin.json (executable rewritten to a basename),
/// <binary> }` that the installer accepts. It does NOT build: the caller runs
/// their native build first (e.g. `swift build -c release`).
///
/// Pure local I/O; no daemon, no mutation of the source tree.
public enum PluginPacker {
    /// Run an I/O closure, surfacing failures as PluginError.ioError with context.
    /// A PluginError thrown inside (e.g. by a nested call) passes through unwrapped.
    private static func io<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PluginError {
            throw error
        } catch {
            throw PluginError.ioError("\(what): \(error.localizedDescription)")
        }
    }

    /// Assemble `source` into a bundle at `output`.
    /// - Parameter force: overwrite a non-empty `output` directory.
    /// - Returns: the bundle directory (== `output`).
    public static func pack(source: URL, output: URL, force: Bool) throws -> URL {
        let fm = FileManager.default

        // 1. Read + validate the source manifest.
        let manifestURL = source.appendingPathComponent("plugin.json")
        let manifestData = try io("read \(manifestURL.path)") { try Data(contentsOf: manifestURL) }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate()

        // 2. Resolve the executable (follow the .build/release symlink) to the real file.
        let resolvedExe = source.appendingPathComponent(manifest.executable)
            .resolvingSymlinksInPath()
        let isRegular =
            (try? resolvedExe.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isRegular else {
            throw PluginError.ioError(
                "executable not found or not a regular file: \(manifest.executable)"
            )
        }

        // 3. Prepare a clean output directory.
        if fm.fileExists(atPath: output.path) {
            let contents = try io("inspect \(output.path)") {
                try fm.contentsOfDirectory(atPath: output.path)
            }
            if !contents.isEmpty && !force {
                throw PluginError.ioError(
                    "output directory is not empty: \(output.path) (use --force to overwrite)"
                )
            }
            try io("clean \(output.path)") { try fm.removeItem(at: output) }
        }
        try io("create \(output.path)") {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
        }

        // 4. Copy the real binary flat, named by the executable's basename.
        let basename = (manifest.executable as NSString).lastPathComponent
        try io("copy executable") { try fm.copyItem(at: resolvedExe, to: output.appendingPathComponent(basename)) }

        // 5. Write plugin.json with ONLY `executable` rewritten. Edit the raw JSON
        //    so any field not modelled by PluginManifest is preserved.
        guard var obj = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw PluginError.invalidManifest("plugin.json is not a JSON object")
        }
        obj["executable"] = basename
        let rewritten = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try io("write manifest") { try rewritten.write(to: output.appendingPathComponent("plugin.json")) }

        // 6. Fail-closed: the bundle must satisfy the installer's own validator.
        try PluginSourceValidator.validate(directory: output)

        return output
    }
}
