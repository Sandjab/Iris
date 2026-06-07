// Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
import XCTest

@testable import IrisKit

final class ShellProfileConfiguratorTests: XCTestCase {
    private func blockCount(in content: String) -> Int {
        content.components(separatedBy: "\n")
            .filter { $0 == ShellProfileConfigurator.beginMarker }
            .count
    }

    // Intent (Rule 9): the managed block must export exactly the 4 vars iris doctor
    // checks, pointing at the real proxy (Config.swift:38) and ca.pem. Breaks if a
    // constant drifts.
    func testRenderBlockContainsCanonicalExports() {
        let block = ShellProfileConfigurator.renderBlock()
        XCTAssertTrue(block.contains(ShellProfileConfigurator.beginMarker))
        XCTAssertTrue(block.contains(ShellProfileConfigurator.endMarker))
        XCTAssertTrue(block.contains("export HTTPS_PROXY=http://127.0.0.1:8888"))
        XCTAssertTrue(block.contains("export HTTP_PROXY=http://127.0.0.1:8888"))
        XCTAssertTrue(block.contains("export NODE_EXTRA_CA_CERTS=\"$HOME/Library/Application Support/iris/ca.pem\""))
        XCTAssertTrue(block.contains("export SSL_CERT_FILE=\"$HOME/Library/Application Support/iris/ca.pem\""))
    }

    func testApplyBlockToEmptyContent() {
        let out = ShellProfileConfigurator.applyBlock(to: "")
        XCTAssertTrue(ShellProfileConfigurator.containsBlock(out))
        XCTAssertEqual(blockCount(in: out), 1)
    }

    func testApplyBlockPreservesExistingContent() {
        let out = ShellProfileConfigurator.applyBlock(to: "export FOO=1\nalias x=y\n")
        XCTAssertTrue(out.contains("export FOO=1"))
        XCTAssertTrue(out.contains("alias x=y"))
        XCTAssertTrue(ShellProfileConfigurator.containsBlock(out))
    }

    func testApplyBlockIsIdempotent() {
        let once = ShellProfileConfigurator.applyBlock(to: "export FOO=1\n")
        let twice = ShellProfileConfigurator.applyBlock(to: once)
        XCTAssertEqual(blockCount(in: twice), 1)
        XCTAssertTrue(twice.contains("export FOO=1"))
    }

    func testApplyBlockReplacesStaleBlock() {
        let stale = "# >>> iris >>>\nexport HTTPS_PROXY=http://127.0.0.1:1111\n# <<< iris <<<\n"
        let out = ShellProfileConfigurator.applyBlock(to: stale)
        XCTAssertEqual(blockCount(in: out), 1)
        XCTAssertFalse(out.contains("1111"))
        XCTAssertTrue(out.contains("8888"))
    }

    func testRemoveBlockRemovesExactlyTheBlock() {
        let content = "export FOO=1\n# >>> iris >>>\nexport HTTPS_PROXY=x\n# <<< iris <<<\nexport BAR=2\n"
        let out = ShellProfileConfigurator.removeBlock(from: content)
        XCTAssertFalse(ShellProfileConfigurator.containsBlock(out))
        XCTAssertTrue(out.contains("export FOO=1"))
        XCTAssertTrue(out.contains("export BAR=2"))
    }

    func testRemoveBlockNoOpWhenAbsent() {
        let content = "export FOO=1\n"
        XCTAssertFalse(ShellProfileConfigurator.containsBlock(ShellProfileConfigurator.removeBlock(from: content)))
        XCTAssertTrue(ShellProfileConfigurator.removeBlock(from: content).contains("export FOO=1"))
    }

    func testRemoveBlockPreservesContentWhenEndMarkerMissing() {
        let content = "export FOO=1\n# >>> iris >>>\nexport HTTPS_PROXY=x\nexport BAR=2\n"
        XCTAssertEqual(ShellProfileConfigurator.removeBlock(from: content), content)
    }

    func testRemoveBlockLeavesOrphanEndMarkerUntouched() {
        let content = "export FOO=1\n# <<< iris <<<\nexport BAR=2\n"
        XCTAssertEqual(ShellProfileConfigurator.removeBlock(from: content), content)
    }

    func testInstallWritesBlockToFile() throws {
        let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "export FOO=1\n".write(toFile: tmp, atomically: true, encoding: .utf8)

        try ShellProfileConfigurator.install(profilePath: tmp)

        let written = try String(contentsOfFile: tmp, encoding: .utf8)
        XCTAssertTrue(written.contains("export FOO=1"))
        XCTAssertTrue(ShellProfileConfigurator.containsBlock(written))
        XCTAssertTrue(ShellProfileConfigurator.isInstalled(profilePath: tmp))
    }

    func testInstallCreatesFileWhenAbsent() throws {
        let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try ShellProfileConfigurator.install(profilePath: tmp)

        XCTAssertTrue(ShellProfileConfigurator.isInstalled(profilePath: tmp))
    }

    func testUninstallRemovesBlockKeepsRest() throws {
        let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "export FOO=1\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        try ShellProfileConfigurator.install(profilePath: tmp)

        try ShellProfileConfigurator.uninstall(profilePath: tmp)

        let written = try String(contentsOfFile: tmp, encoding: .utf8)
        XCTAssertFalse(ShellProfileConfigurator.isInstalled(profilePath: tmp))
        XCTAssertTrue(written.contains("export FOO=1"))
    }

    func testIsInstalledFalseWhenFileAbsent() {
        let tmp = NSTemporaryDirectory() + "iris-absent-\(UUID().uuidString).zshrc"
        XCTAssertFalse(ShellProfileConfigurator.isInstalled(profilePath: tmp))
    }

    func testInstallThrowsOnNonUTF8FileInsteadOfOverwriting() throws {
        let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let invalid = Data([0xFF, 0xFE, 0x00, 0xC0])
        try invalid.write(to: URL(fileURLWithPath: tmp))

        XCTAssertThrowsError(try ShellProfileConfigurator.install(profilePath: tmp))
        let after = try Data(contentsOf: URL(fileURLWithPath: tmp))
        XCTAssertEqual(after, invalid)  // original bytes intact, not overwritten
    }

    func testInstallPreservesFileMode() throws {
        let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "export FOO=1\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)

        try ShellProfileConfigurator.install(profilePath: tmp)

        let mode = try FileManager.default.attributesOfItem(atPath: tmp)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
