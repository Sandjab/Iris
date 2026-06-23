import IrisKit
import Logging
import NIOHTTP1
import XCTest

/// P5: proves the SHIPPED example plugin `header-tagger` (not the test fixture)
/// speaks the NDJSON protocol correctly and does what its README claims — tagging
/// matched requests with `X-Iris-Plugin: header-tagger` while preserving the
/// credential placeholder Iris must still substitute. Runs the real binary under
/// the real PluginSandbox; no proxy/TLS (the full request path is already covered
/// by PluginDispatchE2ETests with the fixture).
final class HeaderTaggerExampleTests: XCTestCase {

    /// Canonical (realpath) scratch dir — Seatbelt canonicalises write paths, so
    /// the profile must carry the realpath (handoff #3). `realpath()` is the URL
    /// extension defined in PluginHostTests.swift (same IntegrationTests target).
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-headertagger-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir.resolvingSymlinksInPath().realpath())
    }

    private func makeHost(scratch: URL) -> PluginHost {
        PluginHost(
            spec: PluginLaunchSpec(
                id: "org.iris.example.header-tagger",
                executablePath: ExecutableLocator.headerTagger.path,
                capabilities: PluginCapabilities(),
                configValues: [:],
                scratchDir: scratch
            ),
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1),
            logger: Logger(label: "test"),
            onUnexpectedExit: { _ in }
        )
    }

    /// Protocol-level: a started host (initialize handshake OK) answers `on_request`
    /// with a `modify` action carrying the tag header.
    func testHeaderTaggerReturnsModifyWithTagHeader() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()

        var caught: Error?
        var result: PluginRPC.OnRequestResult?
        do {
            result = try await host.onRequest(
                PluginRPC.OnRequestParams(
                    method: "POST",
                    uri: "/v1/messages",
                    host: "api.anthropic.com",
                    headers: [
                        ["x-api-key", "{{kc:anthropic_api_key}}"],
                        ["content-type", "application/json"],
                    ],
                    body: nil
                ),
                timeout: 2.0
            )
        } catch {
            caught = error
        }
        await host.shutdown()
        if let caught = caught { throw caught }

        XCTAssertEqual(result?.action, .modify, "header-tagger must return a modify action")
        let tagged = (result?.headers ?? []).contains {
            $0.count == 2 && $0[0].caseInsensitiveCompare("X-Iris-Plugin") == .orderedSame
                && $0[1] == "header-tagger"
        }
        XCTAssertTrue(tagged, "modify result must add X-Iris-Plugin: header-tagger")
    }

    /// Protocol-level: a started host answers `on_response` with a `modify` action
    /// carrying `x-iris-tagged: 1`. Exercises PluginHost.onResponse + the plugin's
    /// new handler end-to-end through the real sandboxed subprocess.
    func testHeaderTaggerReturnsModifyWithTaggedResponseHeader() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()

        var caught: Error?
        var result: PluginRPC.OnResponseResult?
        do {
            result = try await host.onResponse(
                PluginRPC.OnResponseParams(
                    method: "POST",
                    uri: "/v1/messages",
                    host: "api.anthropic.com",
                    status: 200,
                    headers: [["content-type", "text/event-stream"]]
                ),
                timeout: 2.0
            )
        } catch {
            caught = error
        }
        await host.shutdown()
        if let caught = caught { throw caught }

        XCTAssertEqual(result?.action, .modify, "header-tagger must return a modify action for on_response")
        let tagged = (result?.headers ?? []).contains {
            $0.count == 2
                && $0[0].caseInsensitiveCompare("x-iris-tagged") == .orderedSame
                && $0[1] == "1"
        }
        XCTAssertTrue(tagged, "modify result must add x-iris-tagged: 1")
    }

    /// Real delivery: a started host receives an `on_complete` NOTIFICATION and the
    /// plugin records it in its scratch dir. Proves PluginHost.onComplete writes the
    /// notification and the example plugin handles it (no reply expected).
    func testHeaderTaggerRecordsOnCompleteToScratch() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()

        try await host.onComplete(
            PluginRPC.OnCompleteParams(
                method: "POST",
                uri: "/v1/messages",
                host: "api.anthropic.com",
                status: 200,
                durationMs: 7
            )
        )

        // The notification is async; poll the scratch log up to ~2s.
        let logURL = scratch.appendingPathComponent("on_complete.log")
        var contents = ""
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: logURL), let s = String(data: data, encoding: .utf8) {
                contents = s
                if contents.contains("200") { break }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await host.shutdown()

        XCTAssertTrue(
            contents.contains("POST") && contents.contains("200") && contents.contains("/v1/messages"),
            "plugin must record the completion line; got: \(contents.debugDescription)"
        )
    }

    /// Integration with the real HookDispatcher: the overlay merge adds the tag and
    /// PRESERVES the credential placeholder (so Iris can substitute it afterwards).
    func testHeaderTaggerOverlayPreservesCredentialPlaceholder() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()

        let dispatcher = HookDispatcher()
        dispatcher.updateChain([
            PluginChainEntry(
                pluginId: "org.iris.example.header-tagger",
                invoker: host,
                hook: PluginHook(
                    event: .onRequest,
                    match: HookMatch(
                        hosts: ["api.anthropic.com"],
                        methods: ["POST"],
                        pathRegex: "^/v1/"
                    ),
                    mutates: true,
                    onFailure: .skip,
                    timeoutMs: 2000
                )
            )
        ])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages")
        head.headers.add(name: "x-api-key", value: "{{kc:anthropic_api_key}}")
        head.headers.add(name: "content-type", value: "application/json")

        let outcome = await dispatcher.onRequest(head: head, body: nil, host: "api.anthropic.com")
        await host.shutdown()

        guard case .proceed(let outHead, _) = outcome else {
            XCTFail("expected .proceed, got \(outcome)")
            return
        }
        XCTAssertEqual(
            outHead.headers.first(name: "x-iris-plugin"),
            "header-tagger",
            "the tag header must reach the forwarded request"
        )
        XCTAssertEqual(
            outHead.headers.first(name: "x-api-key"),
            "{{kc:anthropic_api_key}}",
            "the credential placeholder must survive the overlay so Iris can substitute it"
        )
    }
}
