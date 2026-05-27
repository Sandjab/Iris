import Foundation

/// Pure text rendering helpers shared between the `iris` CLI and any other
/// tool that needs the same column-aligned output. No I/O, no globals —
/// every function takes its inputs as values and returns a `String`.
public enum TextFormatter {
    /// Render a list of rows as a column-aligned table. Returns header-only
    /// when `rows` is empty. Columns are separated by two spaces and padded
    /// with trailing spaces so every line has identical width.
    public static func table(headers: [String], rows: [[String]]) -> String {
        let widths: [Int] = headers.indices.map { col in
            var width = headers[col].count
            for row in rows where col < row.count {
                width = max(width, row[col].count)
            }
            return width
        }
        let allRows = [headers] + rows
        let lines = allRows.map { row -> String in
            let paddedCells = headers.indices.map { col -> String in
                let cell = col < row.count ? row[col] : ""
                let width = widths[col]
                return cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            return paddedCells.joined(separator: "  ")
        }
        return lines.joined(separator: "\n")
    }

    /// Single-line summary of a `DaemonStatus`.
    public static func status(_ status: DaemonStatus) -> String {
        let s = status.stats
        return "pid=\(status.pid) uptime=\(uptime(seconds: status.uptimeS)) "
            + "version=\(status.version) req=\(s.reqTotal) sub=\(s.subTotal) "
            + "exfil=\(s.exfilBlockedTotal) err=\(s.errorsTotal)"
    }

    /// Render a list of MITM rules as a column-aligned table with HOST, SOURCE,
    /// and CREATED columns. TOML-sourced rules show "—" for creation time
    /// (sentinel epoch-0 is the discriminant used by the dispatcher).
    public static func ruleTable(rules: [MITMRule]) -> String {
        if rules.isEmpty { return "no rules" }
        let formatter = ISO8601DateFormatter()
        let rows = rules.map { rule -> [String] in
            let created: String
            if rule.source == .toml || rule.createdAt.timeIntervalSince1970 == 0 {
                created = "—"
            } else {
                created = formatter.string(from: rule.createdAt)
            }
            return [rule.host, rule.source.rawValue, created]
        }
        return table(headers: ["HOST", "SOURCE", "CREATED"], rows: rows)
    }

    /// Human-friendly uptime ("1d2h", "5m30s", "12s") — keeps the two
    /// most-significant units, drops trailing zero units, always non-empty.
    public static func uptime(seconds total: UInt64) -> String {
        let d = total / 86_400
        let h = (total % 86_400) / 3_600
        let m = (total % 3_600) / 60
        let s = total % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if d == 0 && m > 0 { parts.append("\(m)m") }
        if d == 0 && h == 0 && s > 0 { parts.append("\(s)s") }
        if parts.isEmpty { return "0s" }
        return parts.prefix(2).joined()
    }
}
