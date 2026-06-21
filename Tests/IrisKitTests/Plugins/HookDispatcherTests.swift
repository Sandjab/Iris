import Logging
import NIOCore
import NIOHTTP1
import XCTest

@testable import IrisKit

private actor MockInvoker: PluginInvoking {
    nonisolated let id: String
    private let reply: @Sendable (PluginRPC.OnRequestParams) async throws -> PluginRPC.OnRequestResult
    private var calls = 0
    init(
        id: String,
        reply: @escaping @Sendable (PluginRPC.OnRequestParams) async throws -> PluginRPC.OnRequestResult
    ) {
        self.id = id
        self.reply = reply
    }

    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
    {
        calls += 1
        return try await reply(params)
    }

    var callCount: Int { calls }
}

final class HookDispatcherTests: XCTestCase {
    private func head(
        method: String = "POST",
        uri: String = "/v1/messages",
        headers: [(String, String)] = [("content-type", "application/json")]
    ) -> HTTPRequestHead {
        var h = HTTPHeaders()
        for (n, v) in headers { h.add(name: n, value: v) }
        return HTTPRequestHead(version: .http1_1, method: .init(rawValue: method), uri: uri, headers: h)
    }

    private func entry(
        _ inv: any PluginInvoking,
        match: HookMatch = HookMatch(),
        onFailure: PluginHook.FailureMode = .skip,
        mutates: Bool = true
    ) -> PluginChainEntry {
        PluginChainEntry(
            pluginId: inv.id,
            invoker: inv,
            hook: PluginHook(
                event: .onRequest,
                match: match,
                mutates: mutates,
                onFailure: onFailure,
                timeoutMs: 1000
            )
        )
    }

    func testEmptyChainProceedsUnchanged() async {
        let d = HookDispatcher()
        let h = head()
        let out = await d.onRequest(head: h, body: nil, host: "api.anthropic.com")
        guard case .proceed(let rh, let rb) = out else { return XCTFail("expected .proceed") }
        XCTAssertEqual(rh.uri, h.uri)
        XCTAssertNil(rb)
    }

    func testNoMatchProceedsWithoutInvoking() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateChain([entry(inv, match: HookMatch(hosts: ["other.com"]))])
        _ = await d.onRequest(head: head(), body: nil, host: "api.anthropic.com")
        let calls = await inv.callCount
        XCTAssertEqual(calls, 0, "no IPC when gating fails")
    }

    func testModifyAddsHeader() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .modify, headers: [["x-iris-plugin", "t"]]) }
        let d = HookDispatcher()
        d.updateChain([entry(inv)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail("expected .proceed") }
        XCTAssertEqual(rh.headers.first(name: "x-iris-plugin"), "t")
    }

    func testBlockShortCircuits() async {
        let a = MockInvoker(id: "a") { _ in .init(action: .block, reason: "no") }
        let b = MockInvoker(id: "b") { _ in .init(action: .modify) }
        let d = HookDispatcher()
        d.updateChain([entry(a), entry(b)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .block(let pid, let reason) = out else { return XCTFail("expected .block") }
        XCTAssertEqual(pid, "a")
        XCTAssertEqual(reason, "no")
        let bCalls = await b.callCount
        XCTAssertEqual(bCalls, 0, "chain short-circuits on block")
    }

    func testRespondShortCircuits() async {
        let inv = MockInvoker(id: "p") { _ in
            .init(action: .respond, body: .init(encoding: "utf8", data: "teapot"), status: 418)
        }
        let d = HookDispatcher()
        d.updateChain([entry(inv)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .respond(let pid, let status, _, let body) = out else {
            return XCTFail("expected .respond")
        }
        XCTAssertEqual(pid, "p")
        XCTAssertEqual(status, 418)
        XCTAssertEqual(body?.getString(at: 0, length: body?.readableBytes ?? 0), "teapot")
    }

    func testOnFailureSkipContinues() async {
        struct Boom: Error {}
        let a = MockInvoker(id: "a") { _ in throw Boom() }
        let b = MockInvoker(id: "b") { _ in .init(action: .modify, headers: [["x-b", "1"]]) }
        let d = HookDispatcher()
        d.updateChain([entry(a, onFailure: .skip), entry(b)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail("expected .proceed") }
        XCTAssertEqual(rh.headers.first(name: "x-b"), "1", "skip continues the chain")
    }

    func testOnFailureBlockFailsClosed() async {
        struct Boom: Error {}
        let a = MockInvoker(id: "a") { _ in throw Boom() }
        let d = HookDispatcher()
        d.updateChain([entry(a, onFailure: .block)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .block(let pid, _) = out else { return XCTFail("expected .block") }
        XCTAssertEqual(pid, "a")
    }

    func testChainOrderIsRespected() async {
        let a = MockInvoker(id: "a") { _ in .init(action: .modify, headers: [["x", "a"]]) }
        let b = MockInvoker(id: "b") { p in
            let seen = p.headers.first(where: { $0[0] == "x" })?[1] ?? "?"
            return .init(action: .modify, headers: [["x", seen + "b"]])
        }
        let d = HookDispatcher()
        d.updateChain([entry(a), entry(b)])
        let out = await d.onRequest(head: head(headers: []), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail("expected .proceed") }
        XCTAssertEqual(rh.headers.first(name: "x"), "ab")
    }
}
