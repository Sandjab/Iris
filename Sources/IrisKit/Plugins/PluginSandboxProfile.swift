import Foundation

/// Generates a Seatbelt (SBPL) profile string from a plugin's capabilities.
/// Pure and deterministic — no I/O, fully unit-testable.
///
/// v1 model (cf. docs/plugins-design.md §6):
/// - deny by default;
/// - allow process exec/fork and broad file *read* so a dynamically linked
///   binary can start via dyld (read confidentiality is out of scope v1 —
///   the network deny-by-default below closes the exfil channel);
/// - deny file *write* except the plugin's private scratch dir;
/// - deny network by default; allow only the granted `network` endpoints.
public enum PluginSandboxProfile {
    public static func generate(capabilities: PluginCapabilities, scratchDir: String) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process-fork)",
            "(allow process-exec*)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read*)",
            "(deny file-write*)",
            "(allow file-write* (subpath \(sbplString(scratchDir))))",
            "(deny network*)",
        ]
        for endpoint in capabilities.network {
            // PROVISIONAL — `(remote ip "host:port")` is unverified at runtime: Seatbelt does
            // not resolve DNS hostnames (only literal IPv4/IPv6 are valid in `remote ip`). No
            // network-capable plugin exists in P2a, so this path is not exercised. Fix the SBPL
            // syntax before shipping a plugin that needs network egress.
            // See docs/plugins-design.md §6/§14 and docs/plugins-p2a-plan.md (Self-Review).
            lines.append("(allow network-outbound (remote ip \(sbplString(endpoint))))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a string as an SBPL string literal, escaping backslashes and quotes.
    static func sbplString(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
