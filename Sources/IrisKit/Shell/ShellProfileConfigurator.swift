// Sources/IrisKit/Shell/ShellProfileConfigurator.swift
import Foundation

/// Manages a single marked block of environment exports in the user's shell
/// profile (`~/.zshrc`). The block is delimited by `beginMarker`/`endMarker` so
/// it can be applied idempotently and removed exactly at uninstall — without
/// touching anything else in the file. Pure block logic here is the CI-testable
/// seam; I/O lives in the same enum (Task 2).
public enum ShellProfileConfigurator {
    public static let beginMarker = "# >>> iris >>>"
    public static let endMarker = "# <<< iris <<<"

    /// The canonical 2-variable block IRIS manages. Only `HTTPS_PROXY` and
    /// `NODE_EXTRA_CA_CERTS` are emitted — deliberately:
    ///
    /// - `SSL_CERT_FILE` is intentionally absent. IRIS does selective MITM
    ///   (SPECS §8.3): non-whitelisted hosts are tunnelled with their REAL cert.
    ///   `SSL_CERT_FILE` **replaces** the entire OpenSSL CA bundle (Python, Ruby,
    ///   curl…) with the iris-only `ca.pem`, which would break TLS to every
    ///   tunnelled host. `NODE_EXTRA_CA_CERTS` only **adds** to Node's bundle, so
    ///   it is safe.
    /// - `HTTP_PROXY` is absent because IRIS is HTTPS-only by design.
    ///
    /// Values mirror daemon defaults (`Config.swift:38` → 127.0.0.1:8888) and
    /// the CA export path. Single source of truth; `iris doctor`
    /// (DoctorCommand.swift) checks exactly these two vars.
    public static func renderBlock(
        proxyURL: String = "http://127.0.0.1:8888",
        caPEMPath: String = "$HOME/Library/Application Support/iris/ca.pem"
    ) -> String {
        """
        \(beginMarker)
        export HTTPS_PROXY=\(proxyURL)
        export NODE_EXTRA_CA_CERTS="\(caPEMPath)"
        \(endMarker)
        """
    }

    /// The begin marker alone is the installation sentinel — its presence means
    /// the block is installed (intentional asymmetry: we don't also require the
    /// end marker here, so a half-written block still reads as "installed" and
    /// gets re-applied cleanly).
    public static func containsBlock(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains(beginMarker)
    }

    /// Returns `content` with the iris block removed (between and including the
    /// markers). No-op if absent. Only a *well-formed* block (begin marker WITH
    /// a matching end marker after it) is removed; a malformed block is left
    /// untouched. Line-based for robustness.
    public static func removeBlock(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(of: beginMarker) else { return content }
        // A begin marker without a matching end marker after it is a malformed block:
        // do NOT delete anything (fail-safe — never silently eat profile content below
        // an orphaned marker).
        guard let endIndex = lines[lines.index(after: beginIndex)...].firstIndex(of: endMarker) else {
            return content
        }
        lines.removeSubrange(beginIndex...endIndex)
        return lines.joined(separator: "\n")
    }

    /// Returns `content` with a fresh iris block. Any existing block is removed
    /// first (idempotent + updates stale values). The block is appended with a
    /// blank-line separator when the file is non-empty.
    public static func applyBlock(to content: String, block: String = renderBlock()) -> String {
        var base = removeBlock(from: content)
        while base.hasSuffix("\n") { base.removeLast() }
        if base.isEmpty { return block + "\n" }
        return base + "\n\n" + block + "\n"
    }

    // MARK: - I/O

    /// Default target: the current user's `~/.zshrc` (macOS default shell).
    public static func defaultProfilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc").path
    }

    /// Adds (or refreshes) the iris block in `profilePath`, creating the file if
    /// absent. Atomic write — never a partial file. The file's POSIX mode is
    /// preserved. Only a missing file reads as empty; any other read error
    /// (encoding, permissions, …) propagates so we never overwrite a file we
    /// couldn't fully read.
    public static func install(profilePath: String = defaultProfilePath()) throws {
        let existing: String
        do {
            existing = try String(contentsOfFile: profilePath, encoding: .utf8)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            existing = ""
        }
        try writePreservingMode(applyBlock(to: existing), to: profilePath)
    }

    /// Removes the iris block from `profilePath`. No-op if the file or block is
    /// absent. The file's POSIX mode is preserved across the rewrite.
    public static func uninstall(profilePath: String = defaultProfilePath()) throws {
        guard let existing = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return }
        guard containsBlock(existing) else { return }
        try writePreservingMode(removeBlock(from: existing), to: profilePath)
    }

    /// Whether the iris block is present in `profilePath`. Fail-safe: any read
    /// error (missing file, unreadable, non-UTF-8) reads as not installed.
    public static func isInstalled(profilePath: String = defaultProfilePath()) -> Bool {
        guard let existing = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return false }
        return containsBlock(existing)
    }

    /// Atomic write that restores the file's prior POSIX mode — `String.write`
    /// recreates the file under the process umask, which would otherwise reset a
    /// hardened (e.g. 0600) profile to ~0644.
    private static func writePreservingMode(_ content: String, to path: String) throws {
        let previousMode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        if let mode = previousMode {
            // Content is already written correctly; a failed mode-restore is non-fatal.
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }
}
