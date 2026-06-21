import XCTest

@testable import IrisKit

final class PluginSandboxProfileTests: XCTestCase {
    func testDeniesByDefaultAndAllowsScratchWrite() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: "/tmp/iris-scratch/foo"
        )
        XCTAssertTrue(profile.contains("(version 1)"))
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(allow process-exec*)"))
        XCTAssertTrue(profile.contains("(allow file-read*)"))
        XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"/tmp/iris-scratch/foo\"))"))
        XCTAssertTrue(profile.contains("(deny network*)"))
    }

    func testNoNetworkAllowLinesWhenCapabilityEmpty() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(network: [], filesystem: []),
            scratchDir: "/tmp/s"
        )
        XCTAssertFalse(profile.contains("network-outbound"))
    }

    func testNetworkAllowLinesWhenGranted() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(network: ["api.example.com:443"], filesystem: []),
            scratchDir: "/tmp/s"
        )
        XCTAssertTrue(
            profile.contains("(allow network-outbound (remote ip \"api.example.com:443\"))")
        )
    }

    func testEscapesScratchPath() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: "/tmp/a\"b\\c"
        )
        XCTAssertTrue(profile.contains("(subpath \"/tmp/a\\\"b\\\\c\")"))
    }
}
