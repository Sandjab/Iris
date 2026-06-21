import Foundation

/// Validates a client-supplied plugin source tree before it is copied into the
/// per-user plugins dir (design §14 #8). Two guarantees, both fail-closed:
///
/// 1. **No symbolic links.** `PluginHasher` only folds regular files into the
///    TOFU pin, so a symlink is unpinned — its target could change after install
///    without moving the hash, and an absolute link could point outside the
///    bundle. A legitimate plugin bundle needs no symlinks, so we refuse any.
/// 2. **Bounded size/count.** A verbatim copy of an arbitrary directory is a DoS
///    vector (disk fill, huge re-hash). Cap total bytes and file count.
///
/// Pure I/O over the source dir; no mutation.
public enum PluginSourceValidator {
    public struct Limits: Sendable {
        public let maxFileCount: Int
        public let maxTotalBytes: Int
        public init(maxFileCount: Int = 10_000, maxTotalBytes: Int = 100 * 1024 * 1024) {
            self.maxFileCount = maxFileCount
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public static func validate(directory: URL, limits: Limits = Limits()) throws {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory.standardizedFileURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else {
            throw PluginError.ioError("cannot enumerate source \(directory.path)")
        }
        var fileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                throw PluginError.unsafeSource("contains a symbolic link: \(url.lastPathComponent)")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            if fileCount > limits.maxFileCount {
                throw PluginError.unsafeSource("too many files (> \(limits.maxFileCount))")
            }
            totalBytes += values.fileSize ?? 0
            if totalBytes > limits.maxTotalBytes {
                throw PluginError.unsafeSource("source too large (> \(limits.maxTotalBytes) bytes)")
            }
        }
    }
}
