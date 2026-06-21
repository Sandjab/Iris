import IrisKit
import Logging
import XCTest

/// Drives a real PluginHost against the iris-test-plugin fixture, through the
/// real PluginSandbox + iris-sandbox-exec shim. Proves the initialize handshake
/// and the graceful/forced shutdown paths end-to-end under the sandbox.
final class PluginHostTests: XCTestCase {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seatbelt canonicalises write paths via realpath; the profile must carry
        // the canonical path or scratch writes fail closed (handoff #3).
        return URL(fileURLWithPath: dir.resolvingSymlinksInPath().realpath())
    }

    private func makeHost(scratch: URL) -> PluginHost {
        // Point straight at the fixture binary, which defaults to mode "ok"
        // (replies ready + writes the scratch marker). PluginSandbox passes no
        // argv to the plugin, matching production. Alternate fixture modes
        // (crash / ignore-shutdown) are exercised at the manager level (Task 6)
        // via an installed `run.sh` launcher that bakes the mode in.
        let spec = PluginLaunchSpec(
            id: "test.host",
            executablePath: ExecutableLocator.testPlugin.path,
            capabilities: PluginCapabilities(),
            configValues: [:],
            scratchDir: scratch
        )
        return PluginHost(
            spec: spec,
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1),
            logger: Logger(label: "test"),
            onUnexpectedExit: { _ in }
        )
    }

    func testOnRequestPassRoundTrip() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()
        let result = try await host.onRequest(
            PluginRPC.OnRequestParams(
                method: "POST",
                uri: "/v1/x",
                host: "h",
                headers: [["x-test-action", "pass"]],
                body: nil
            ),
            timeout: 2
        )
        XCTAssertEqual(result.action, .pass)
        await host.shutdown()
    }

    func testOnRequestModifyAddsHeader() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()
        let result = try await host.onRequest(
            PluginRPC.OnRequestParams(
                method: "POST",
                uri: "/v1/x",
                host: "h",
                headers: [["x-test-action", "modify"]],
                body: nil
            ),
            timeout: 2
        )
        XCTAssertEqual(result.action, .modify)
        XCTAssertTrue((result.headers ?? []).contains(["x-iris-plugin", "test"]))
        await host.shutdown()
    }

    func testOnRequestTimeoutThrows() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()
        do {
            _ = try await host.onRequest(
                PluginRPC.OnRequestParams(
                    method: "POST",
                    uri: "/v1/x",
                    host: "h",
                    headers: [["x-test-action", "hang"]],
                    body: nil
                ),
                timeout: 0.3
            )
            XCTFail("expected timeout")
        } catch let error as PluginHostError {
            if case .timeout = error {
                // Only the per-call timeout is expected here.
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
        await host.shutdown()
    }

    func testInitializeHandshakeAndScratchMarker() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()
        // The fixture writes an "initialized" marker into scratch_dir on initialize.
        let marker = scratch.appendingPathComponent("initialized")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "plugin should have written its scratch marker during initialize"
        )
        await host.shutdown()
    }
}

extension URL {
    /// Canonical filesystem path via realpath(3). `resolvingSymlinksInPath()` does
    /// not resolve the APFS `/var` firmlink, which Seatbelt requires (handoff #3).
    func realpath() -> String {
        path.withCString { cString in
            guard let resolved = Darwin.realpath(cString, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
