import Foundation
import XCTest

/// De-risks the deprecated Seatbelt API: proves the shim links
/// `sandbox_init_with_parameters`, applies a profile, and execs a real binary
/// whose output flows back. Uses an allow-all profile here so this test isolates
/// "does the API/plumbing work" from "is our deny-default profile workable"
/// (the latter is PluginSandboxEnforcementTests).
final class PluginShimSmokeTests: XCTestCase {
    private func wait(for process: Process, timeout: TimeInterval = 5.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("process did not exit within \(timeout)s")
        }
    }

    private func runShim(_ args: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = ExecutableLocator.sandboxExec
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        wait(for: process)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testUsageErrorWhenTooFewArguments() throws {
        let result = try runShim(["only-one-arg"])
        XCTAssertEqual(result.status, 64)
    }

    func testAppliesProfileAndExecsBinary() throws {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shim-smoke-\(UUID().uuidString).sb")
        try "(version 1)\n(allow default)\n".write(to: profileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        let result = try runShim([profileURL.path, "/bin/echo", "hello-from-sandbox"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(
            result.stdout.contains("hello-from-sandbox"),
            "expected echo output, got: \(result.stdout)"
        )
    }
}
