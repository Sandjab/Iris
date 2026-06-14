import AppKit
import IrisAppCore
import SwiftUI

/// Fenêtre « À propos » : en-tête (icône de l'app + nom + version lue depuis
/// `Bundle.main`) suivi d'une zone scrollable affichant les notes de version
/// (`CHANGELOG.md` embarqué dans le bundle). Le rendu Markdown est fait ici ;
/// le chargement/parsing pur vit dans `IrisAppCore.ReleaseNotes` (testable).
struct AboutWindow: View {
    private let version = ReleaseNotes.appVersion() ?? "—"
    private let blocks: [ChangelogBlock] = {
        guard let markdown = ReleaseNotes.loadMarkdown() else { return [] }
        return ReleaseNotes.releaseSections(ReleaseNotes.parse(markdown))
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            notes
        }
        .frame(minWidth: 380, minHeight: 360)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Iris")
                .font(.title2)
                .bold()
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if blocks.isEmpty {
                    Text("Release notes are unavailable.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(16)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChangelogBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(for: level))
                .bold()
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(inline(text))
            }
            .padding(.leading, 4)
        case .paragraph(let text):
            Text(inline(text))
                .foregroundStyle(.secondary)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }

    /// Renders inline Markdown (`**bold**`, `` `code` ``, links) for a single
    /// line; falls back to plain text if the line isn't valid Markdown.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
