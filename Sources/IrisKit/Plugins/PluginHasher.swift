import Crypto
import Foundation

/// Stable SHA-256 digest of a plugin directory's contents, used for the TOFU
/// pin. Both the relative path AND the bytes of every regular file are folded
/// in (sorted by path), so a rename, an added/removed file, or a content edit
/// all change the digest. Directories themselves contribute only via their
/// files' paths.
///
/// Every regular file is covered, INCLUDING hidden ones (dotfiles): a manifest
/// executable may legitimately have a leading dot (`isSafePathComponent`
/// permits it), so a hidden file is loadable and must be pinned. The flip side
/// is that any post-install mutation — even a stray `.DS_Store` — changes the
/// digest and forces re-approval; that is the intended TOFU behavior.
public enum PluginHasher {
    public static func hash(directory: URL) throws -> String {
        let files = try regularFiles(in: directory)
        var hasher = SHA256()
        for file in files {
            // Length-prefixed path then length-prefixed contents → no ambiguity
            // between e.g. ("ab","c") and ("a","bc").
            hasher.update(data: Self.lengthPrefixed(Data(file.rel.utf8)))
            let contents = try Data(contentsOf: file.url)
            hasher.update(data: Self.lengthPrefixed(contents))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cheap stat-only fingerprint of the tree: the sorted (relative path, mtime,
    /// size) of every regular file — the SAME set `hash` folds in. An unchanged
    /// signature ⇒ unchanged content, so a caller can skip the (far costlier)
    /// content `hash`. Detects add/remove/rename (path set changes) and in-place
    /// edits (size or mtime change). Residual blind spot: an edit preserving BOTH
    /// byte count AND nanosecond mtime — only reachable by someone with write
    /// access to the 0600 user-owned plugins dir, who has already crossed the
    /// trust boundary. Stricter than the design's "mtime"-only invalidation (it
    /// also folds in path set + size). Cf. docs/plugins-design.md §14 #9.
    public static func signature(directory: URL) throws -> String {
        let files = try regularFiles(in: directory)
        var parts: [String] = []
        parts.reserveCapacity(files.count)
        for file in files {
            let values = try file.url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ])
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values.fileSize ?? 0
            parts.append("\(file.rel)\u{0}\(mtime)\u{0}\(size)")
        }
        return parts.joined(separator: "\n")
    }

    /// Sorted regular files (hidden included) under `directory`, as (relative
    /// path, url). Shared by `hash` and `signature` so both cover the exact same
    /// set. Throws if a file resolves outside `directory` (defense against an
    /// enumerator surprise).
    private static func regularFiles(in directory: URL) throws -> [(rel: String, url: URL)] {
        let fm = FileManager.default
        let base = directory.standardizedFileURL
        guard
            let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else {
            throw PluginError.ioError("cannot enumerate \(base.path)")
        }
        var files: [(rel: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let absPath = url.standardizedFileURL.path
            let prefix = base.path + "/"
            guard absPath.hasPrefix(prefix) else {
                throw PluginError.ioError("path \(absPath) outside base \(base.path)")
            }
            let rel = String(absPath.dropFirst(prefix.count))
            files.append((rel: rel, url: url))
        }
        files.sort { $0.rel < $1.rel }
        return files
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
