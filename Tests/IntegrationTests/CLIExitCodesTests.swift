import XCTest

final class CLIExitCodesTests: XCTestCase {
    func testStatusExitsTwoWhenDaemonUnreachable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-noexist-\(UUID().uuidString).sock").path
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["status", "--socket-path", tmp]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 2)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("irisd not running"), "stderr=\(stderr)")
        XCTAssertTrue(stderr.contains("launchctl kickstart"), "stderr=\(stderr)")
    }

    func testRuleAddExitsUsage() throws {
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["rule", "add", "foo.example.com"]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 64)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Phase 4.x"))
    }

    func testConfigReloadExitsUsage() throws {
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["config", "reload"]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 64)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("Phase 4.x"))
    }
}
