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

    private var completeRecords: [PluginRPC.OnCompleteParams] = []
    private var completeError: Error?
    private var blockOnComplete = false
    private var released = false
    func setOnCompleteThrows(_ error: Error) { completeError = error }
    func setBlocksOnComplete() { blockOnComplete = true }
    func releaseOnComplete() { released = true }
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
        if let completeError { throw completeError }
        // Block until released (models a slow/blocked sink). Each `await` suspends
        // the actor, so `releaseOnComplete()` can still run while we spin here.
        while blockOnComplete && !released {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        completeRecords.append(params)
    }
    var completeCalls: [PluginRPC.OnCompleteParams] { completeRecords }
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

    private func completeEntry(_ inv: any PluginInvoking, match: HookMatch = HookMatch()) -> PluginChainEntry {
        PluginChainEntry(
            pluginId: inv.id,
            invoker: inv,
            hook: PluginHook(event: .onComplete, match: match, mutates: false, onFailure: .skip, timeoutMs: 1000)
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
        XCTAssertEqual(
            rh.headers.first(name: "content-type"),
            "application/json",
            "overlay preserves unspecified headers"
        )
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

    func testRespondStatusOutOfRangeClampsTo200() async {
        // A plugin returning an invalid status must not crash the daemon: NIO's
        // HTTPResponseStatus(statusCode:) does `UInt(statusCode)`, which TRAPS on a
        // negative int. The dispatcher clamps any out-of-range status to 200.
        for badStatus in [-1, 0, 99, 600, 99_999] {
            let inv = MockInvoker(id: "p") { _ in .init(action: .respond, status: badStatus) }
            let d = HookDispatcher()
            d.updateChain([entry(inv)])
            let out = await d.onRequest(head: head(), body: nil, host: "h")
            guard case .respond(_, let status, _, _) = out else {
                return XCTFail("expected .respond for status \(badStatus)")
            }
            XCTAssertEqual(status, 200, "out-of-range status \(badStatus) must clamp to 200")
        }
    }

    func testRespondStatusInRangeIsPreserved() async {
        // Boundary values of the valid HTTP range must pass through unchanged.
        for goodStatus in [100, 200, 418, 599] {
            let inv = MockInvoker(id: "p") { _ in .init(action: .respond, status: goodStatus) }
            let d = HookDispatcher()
            d.updateChain([entry(inv)])
            let out = await d.onRequest(head: head(), body: nil, host: "h")
            guard case .respond(_, let status, _, _) = out else {
                return XCTFail("expected .respond for status \(goodStatus)")
            }
            XCTAssertEqual(status, goodStatus, "in-range status \(goodStatus) must be preserved")
        }
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

    func testOnCompleteDeliversParamsToMatchingPlugin() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateCompleteChain([completeEntry(inv, match: HookMatch(hosts: ["api.anthropic.com"]))])
        await d.onComplete(
            method: "POST",
            uri: "/v1/messages",
            host: "api.anthropic.com",
            contentType: "application/json",
            status: 200,
            durationMs: 12
        )
        let records = await inv.completeCalls
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, 200)
        XCTAssertEqual(records.first?.uri, "/v1/messages")
    }

    func testOnCompleteSkipsNonMatchingPlugin() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateCompleteChain([completeEntry(inv, match: HookMatch(status: [500]))])
        await d.onComplete(
            method: "GET",
            uri: "/x",
            host: "h",
            contentType: nil,
            status: 200,
            durationMs: 1
        )
        let records = await inv.completeCalls
        XCTAssertTrue(records.isEmpty, "status condition [500] must not match a 200 completion")
    }

    func testOnCompleteEmptyChainIsNoop() async {
        // A plugin present in the onRequest chain must NOT be invoked by onComplete
        // when the onComplete chain is empty — the two chains are independent.
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateChain([entry(inv)])
        await d.onComplete(
            method: "GET",
            uri: "/x",
            host: "h",
            contentType: nil,
            status: 0,
            durationMs: 1
        )
        let calls = await inv.completeCalls
        XCTAssertTrue(calls.isEmpty, "onComplete must read its own chain, not the onRequest chain")
    }

    func testOnCompleteSwallowsPluginErrors() async {
        struct Boom: Error {}
        let bad = MockInvoker(id: "bad") { _ in .init(action: .pass) }
        await bad.setOnCompleteThrows(Boom())
        let d = HookDispatcher()
        d.updateCompleteChain([completeEntry(bad)])
        // Must not throw / crash — onComplete is fire-and-forget; errors are logged.
        await d.onComplete(method: "GET", uri: "/x", host: "h", contentType: nil, status: 0, durationMs: 1)
    }

    func testOnCompleteDispatchesConcurrentlyAcrossPlugins() async {
        // A blocks until released; B records immediately. Concurrent dispatch delivers
        // to B even while A is blocked. A SEQUENTIAL dispatch (A is first in the chain)
        // would block B behind A → B would never record until A is released, and this
        // test would fail. This guards the design-C8 "independent per plugin" property.
        let a = MockInvoker(id: "a") { _ in .init(action: .pass) }
        let b = MockInvoker(id: "b") { _ in .init(action: .pass) }
        await a.setBlocksOnComplete()
        let d = HookDispatcher()
        // A is first: a sequential loop would head-of-line block on it.
        d.updateCompleteChain([completeEntry(a), completeEntry(b)])

        let dispatch = Task {
            await d.onComplete(method: "GET", uri: "/x", host: "h", contentType: nil, status: 200, durationMs: 1)
        }

        var bRecorded = false
        for _ in 0..<400 {
            if await !b.completeCalls.isEmpty {
                bRecorded = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let aRecordedWhileBlocked = await !a.completeCalls.isEmpty
        XCTAssertTrue(bRecorded, "B is delivered concurrently while A is still blocked")
        XCTAssertFalse(aRecordedWhileBlocked, "A is still blocked, so it has not recorded yet")

        await a.releaseOnComplete()
        await dispatch.value
        let aRecorded = await !a.completeCalls.isEmpty
        XCTAssertTrue(aRecorded, "A records once released (it was dispatched, not dropped)")
    }
}
