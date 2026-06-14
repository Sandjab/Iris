import XCTest

@testable import IrisAppCore

final class ReleaseNotesTests: XCTestCase {
    // Heading depth carries the changelog hierarchy (version vs category); the
    // view maps each level to a distinct font, so the level must survive parsing.
    func testHeadingLevelsArePreserved() {
        let blocks = ReleaseNotes.parse("# Changelog\n## [1.0.1]\n### Added")
        XCTAssertEqual(
            blocks,
            [
                .heading(level: 1, text: "Changelog"),
                .heading(level: 2, text: "[1.0.1]"),
                .heading(level: 3, text: "Added"),
            ]
        )
    }

    // Both `-` and `*` are bullets; the marker is presentation and must not leak
    // into the rendered text.
    func testBulletMarkersAreStripped() {
        let blocks = ReleaseNotes.parse("- one\n* two")
        XCTAssertEqual(blocks, [.bullet("one"), .bullet("two")])
    }

    // The bundled CHANGELOG wraps bullets across lines with a 2-space indent.
    // Without folding, each continuation would render as a stray paragraph under
    // the bullet — this is the case that justifies the continuation logic.
    func testWrappedBulletFoldsContinuationLine() {
        let blocks = ReleaseNotes.parse("- first part\n  second part")
        XCTAssertEqual(blocks, [.bullet("first part second part")])
    }

    // Keep-a-Changelog separates sections with blank lines; they must not become
    // empty blocks (which would render as gaps the view doesn't control).
    func testBlankLinesAreDropped() {
        let blocks = ReleaseNotes.parse("# A\n\n\n- b")
        XCTAssertEqual(blocks, [.heading(level: 1, text: "A"), .bullet("b")])
    }

    // Inline markup is intentionally left untouched by the core: rendering it is
    // the view's job. This test fails if inline parsing creeps into the core.
    func testInlineMarkupIsLeftToTheView() {
        let blocks = ReleaseNotes.parse("- **bold** and `code`")
        XCTAssertEqual(blocks, [.bullet("**bold** and `code`")])
    }

    // ATX headings require a space after the hashes; `#tag` is prose, not a title.
    func testHashWithoutSpaceIsParagraph() {
        let blocks = ReleaseNotes.parse("#notaheading")
        XCTAssertEqual(blocks, [.paragraph("#notaheading")])
    }

    // The About window shows release notes, not the "Changelog / Keep a Changelog"
    // preamble — sections start at the first version heading (level 2).
    func testReleaseSectionsDropPreambleBeforeFirstVersion() {
        let blocks = ReleaseNotes.parse("# Changelog\nintro line\n## [1.0.1]\n- thing")
        XCTAssertEqual(
            ReleaseNotes.releaseSections(blocks),
            [.heading(level: 2, text: "[1.0.1]"), .bullet("thing")]
        )
    }

    // With no version heading there is nothing to trim; keep everything rather
    // than silently returning an empty view.
    func testReleaseSectionsKeepsAllWhenNoVersionHeading() {
        let blocks = ReleaseNotes.parse("# Changelog\nintro")
        XCTAssertEqual(ReleaseNotes.releaseSections(blocks), blocks)
    }

    func testPlainLineIsParagraph() {
        XCTAssertEqual(ReleaseNotes.parse("Just text."), [.paragraph("Just text.")])
    }

    func testEmptyInputYieldsNoBlocks() {
        XCTAssertEqual(ReleaseNotes.parse(""), [])
    }

    // A bundle without the resource must degrade to nil, never crash — the About
    // window falls back to a short message in that case.
    func testLoadMarkdownReturnsNilWhenAbsent() {
        XCTAssertNil(ReleaseNotes.loadMarkdown(from: Bundle(for: Self.self)))
    }
}
