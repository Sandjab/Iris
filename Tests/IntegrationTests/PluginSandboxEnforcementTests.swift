import Foundation
import IrisKit
import NIOCore
import NIOPosix
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
        // Seatbelt canonicalises write paths before matching the profile's
        // (subpath …) filter (e.g. /var/folders → /private/var/folders), so the
        // scratch path fed to the generator must already be canonical — otherwise
        // file-write inside scratch is wrongly denied. URL.resolvingSymlinksInPath()
        // does NOT resolve the /var firmlink on APFS, so use realpath(3). Production
        // (P2b) must likewise hand the generator a canonical scratch path.
        guard let resolved = realpath(dir.path, nil) else { return dir }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
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

    func testFileWriteDeniedOutsideScratchAllowedInside() throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )

        // (a) write OUTSIDE scratch → denied → sh exits non-zero, file absent.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        let denied = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo x > \(outside.path)"],
            profile: profile
        )
        denied.waitUntilExit()
        XCTAssertNotEqual(denied.terminationStatus, 0, "write outside scratch must be denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))

        // (b) write INSIDE scratch → allowed → sh exits 0, file present.
        let inside = scratch.appendingPathComponent("ok.txt")
        let allowed = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo x > \(inside.path)"],
            profile: profile
        )
        allowed.waitUntilExit()
        XCTAssertEqual(allowed.terminationStatus, 0, "write inside scratch must be allowed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testNetworkDeniedByDefault() throws {
        // Ephemeral TCP listener so the connect probe has a real peer.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { try? server.close().wait() }
        guard let port = server.localAddress?.port else {
            return XCTFail("listener has no port")
        }
        let probe = "exec 3<>/dev/tcp/127.0.0.1/\(port)"

        // Control: NO sandbox → the /dev/tcp connect succeeds (status 0).
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sh")
        control.arguments = ["-c", probe]
        try control.run()
        control.waitUntilExit()
        XCTAssertEqual(control.terminationStatus, 0, "control: connect should work without sandbox")

        // Sandboxed: deny network* → connect blocked → status non-zero.
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )
        let blocked = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", probe],
            profile: profile
        )
        blocked.waitUntilExit()
        XCTAssertNotEqual(blocked.terminationStatus, 0, "sandbox must deny outbound network")
    }
}
