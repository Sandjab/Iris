import Foundation

/// A parsed block of the changelog. Kept free of SwiftUI so the parsing logic
/// stays testable in the core; the view layer maps each case to a concrete style.
public enum ChangelogBlock: Sendable, Equatable {
    /// A heading; `level` is the Markdown depth (1 = `#`, 2 = `##`, …).
    case heading(level: Int, text: String)
    /// A bullet list item (the leading `-`/`*` marker stripped).
    case bullet(String)
    /// A plain paragraph line.
    case paragraph(String)
}

/// Loads the release notes bundled with the app (`CHANGELOG.md`) and reads the
/// app version. The string→blocks parsing is pure (and tested); rendering lives
/// in the app's SwiftUI layer.
public enum ReleaseNotes {
    /// The marketing version (`CFBundleShortVersionString`) of `bundle`, or nil.
    public static func appVersion(from bundle: Bundle = .main) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The raw `CHANGELOG.md` text bundled with `bundle`, or nil if absent.
    public static func loadMarkdown(from bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Parses Keep-a-Changelog Markdown into renderable blocks. Only block
    /// structure (headings, bullets) is interpreted here; inline markup
    /// (`**bold**`, `` `code` ``, links) is left in the text for the view to
    /// render. Blank lines are dropped (the view spaces blocks itself) and lines
    /// indented under a block are folded back into it as wrapped continuations.
    public static func parse(_ markdown: String) -> [ChangelogBlock] {
        var blocks: [ChangelogBlock] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let isContinuation = rawLine.first == " " || rawLine.first == "\t"
            // .whitespacesAndNewlines also strips a trailing `\r` so CRLF-encoded
            // CHANGELOG.md files (Git core.autocrlf) don't leave invisible carriage
            // returns at the end of each rendered line.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if isContinuation, let last = blocks.last {
                blocks[blocks.count - 1] = appending(line, to: last)
                continue
            }
            if let heading = heading(from: line) {
                blocks.append(heading)
            } else if let bullet = bullet(from: line) {
                blocks.append(.bullet(bullet))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    /// Drops the changelog preamble (the `# Changelog` title and format blurb) so
    /// the About window shows only the per-version sections — everything from the
    /// first level-2 heading on. Returns the input unchanged if there is none.
    public static func releaseSections(_ blocks: [ChangelogBlock]) -> [ChangelogBlock] {
        guard
            let start = blocks.firstIndex(where: {
                if case .heading(let level, _) = $0 { return level == 2 }
                return false
            })
        else { return blocks }
        return Array(blocks[start...])
    }

    private static func heading(from line: String) -> ChangelogBlock? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(from line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func appending(_ text: String, to block: ChangelogBlock) -> ChangelogBlock {
        switch block {
        case .heading(let level, let head): return .heading(level: level, text: head + " " + text)
        case .bullet(let body): return .bullet(body + " " + text)
        case .paragraph(let body): return .paragraph(body + " " + text)
        }
    }
}
