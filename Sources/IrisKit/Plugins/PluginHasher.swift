import Crypto
import Foundation

/// Stable SHA-256 digest of a plugin directory's contents, used for the TOFU
/// pin. Both the relative path AND the bytes of every regular file are folded
/// in (sorted by path), so a rename, an added/removed file, or a content edit
/// all change the digest. Directories themselves contribute only via their
/// files' paths.
public enum PluginHasher {
    public static func hash(directory: URL) throws -> String {
        let fm = FileManager.default
        let base = directory.standardizedFileURL
        guard
            let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw PluginError.ioError("cannot enumerate \(base.path)")
        }

        var files: [(rel: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = url.standardizedFileURL.path
                .replacingOccurrences(of: base.path + "/", with: "")
            files.append((rel: rel, url: url))
        }
        files.sort { $0.rel < $1.rel }

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

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
