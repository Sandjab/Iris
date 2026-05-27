import XCTest

final class CLIExitCodesTests: XCTestCase {

    // MARK: - Helpers

    /// Waits for `process` to exit within `timeout` seconds. Terminates (then
    /// kills) the process if it does not exit in time, and fails the test.
    private func waitWithTimeout(
        _ process: Process,
        timeout: TimeInterval = 10,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            XCTFail("process did not exit within \(timeout)s", file: file, line: line)
        }
    }

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
        waitWithTimeout(process)

        XCTAssertEqual(process.terminationStatus, 2)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("irisd not running"), "stderr=\(stderr)")
        XCTAssertTrue(stderr.contains("launchctl kickstart"), "stderr=\(stderr)")
    }

    func testSecretListAlsoExitsTwoWhenDaemonUnreachable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-noexist-\(UUID().uuidString).sock").path
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["secret", "list", "--socket-path", tmp]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        waitWithTimeout(process)

        XCTAssertEqual(process.terminationStatus, 2)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("irisd not running"), "stderr=\(stderr)")
    }

    func testRuleAddExitsTwoWhenDaemonUnreachable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-noexist-\(UUID().uuidString).sock").path
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["rule", "add", "foo.example.com", "--socket-path", tmp]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        waitWithTimeout(process)
        XCTAssertEqual(process.terminationStatus, 2)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("irisd not running"), "stderr=\(stderr)")
    }

    func testConfigReloadExitsTwoWhenDaemonUnreachable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-noexist-\(UUID().uuidString).sock").path
        let process = Process()
        process.executableURL = ExecutableLocator.iris
        process.arguments = ["config", "reload", "--socket-path", tmp]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        waitWithTimeout(process)
        XCTAssertEqual(process.terminationStatus, 2)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("irisd not running"), "stderr=\(stderr)")
    }
}
