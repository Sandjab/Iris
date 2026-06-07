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

    /// The exact exports IRIS manages. Values mirror the daemon defaults
    /// (`Config.swift:38` → 127.0.0.1:8888) and the CA export path
    /// (`~/Library/Application Support/iris/ca.pem`). Single source of truth;
    /// `iris doctor` (DoctorCommand.swift:109) checks exactly these four vars.
    public static func renderBlock(
        proxyURL: String = "http://127.0.0.1:8888",
        caPEMPath: String = "$HOME/Library/Application Support/iris/ca.pem"
    ) -> String {
        """
        \(beginMarker)
        export HTTPS_PROXY=\(proxyURL)
        export HTTP_PROXY=\(proxyURL)
        export NODE_EXTRA_CA_CERTS="\(caPEMPath)"
        export SSL_CERT_FILE="\(caPEMPath)"
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
}
