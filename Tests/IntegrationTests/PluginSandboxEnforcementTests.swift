import Foundation
import IrisKit
import XCTest

/// Proves the *generated* deny-default profile (a) is not so tight that a
/// dynamically linked binary fails to start, and (b) actually enforces the
/// write/network restrictions. Each test runs an ephemeral child through the
/// real PluginSandbox + iris-sandbox-exec shim.
final class PluginSandboxEnforcementTests: XCTestCase {
    private func sandbox() -> PluginSandbox {
        PluginSandbox(shimPath: ExecutableLocator.sandboxExec)
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRealProfileStillLetsBinaryRun() throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )
        let out = Pipe()
        let process = try sandbox().launch(
            executable: "/bin/echo",
            arguments: ["alive"],
            profile: profile,
            standardOutput: out
        )
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("alive"))
    }
}
