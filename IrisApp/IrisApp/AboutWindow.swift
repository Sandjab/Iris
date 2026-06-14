import AppKit
import IrisAppCore
import SwiftUI

/// Fenêtre « À propos » : en-tête (icône de l'app + nom + version lue depuis
/// `Bundle.main`) suivi d'une zone scrollable affichant les notes de version
/// (`CHANGELOG.md` embarqué dans le bundle). Le chargement/parsing pur vit dans
/// `IrisAppCore.ReleaseNotes` (testable) ; le Markdown inline est converti une
/// seule fois dans l'`init` (le `body` SwiftUI peut être réévalué à chaque frame).
struct AboutWindow: View {
    /// Un bloc du changelog avec son texte Markdown déjà rendu. `id` stable (index
    /// dans une liste statique calculée une fois) — pas d'index passé à `ForEach`.
    private struct RenderedBlock: Identifiable {
        let id: Int
        let block: ChangelogBlock
        let text: AttributedString
    }

    private let version = ReleaseNotes.appVersion() ?? "—"
    private let blocks: [RenderedBlock]

    init() {
        let raw: [ChangelogBlock] = {
            guard let markdown = ReleaseNotes.loadMarkdown() else { return [] }
            return ReleaseNotes.releaseSections(ReleaseNotes.parse(markdown))
        }()
        blocks = raw.enumerated().map { index, block in
            let source: String
            switch block {
            case .heading(_, let text), .bullet(let text), .paragraph(let text):
                source = text
            }
            // Inline Markdown (`**bold**`, `` `code` ``, links); plain text otherwise.
            let rendered = (try? AttributedString(markdown: source)) ?? AttributedString(source)
            return RenderedBlock(id: index, block: block, text: rendered)
        }
    }

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
                    ForEach(blocks) { rendered in
                        blockView(rendered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(16)
        }
    }

    @ViewBuilder
    private func blockView(_ rendered: RenderedBlock) -> some View {
        switch rendered.block {
        case .heading(let level, _):
            Text(rendered.text)
                .font(headingFont(for: level))
                .bold()
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(rendered.text)
            }
            .padding(.leading, 4)
        case .paragraph:
            Text(rendered.text)
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
}
