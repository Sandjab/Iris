# onResponse (mode `metadata`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `onResponse` plugin hook in `metadata` mode — a plugin observes a response's status + headers at the upstream response head and may overlay response headers before relay, never touching the body.

**Architecture:** A new `on_response` request/response IPC method + a separate ordered chain in `HookDispatcher`. `MITMHandler` builds a `responseHeadHook` closure (nil when no plugin pre-matches → response path byte-for-byte identical to today) and passes it to `UpstreamClient.stream`. `UpstreamResponseRelay` runs the hook at the response head, queueing any body parts that arrive during the (timeout-bounded) hook round-trip, then relays the (possibly modified) head and drains the queue. Body parts stream unchanged — §7.2/§7.3 (response *bodies*) untouched.

**Tech Stack:** Swift 5.9+, SwiftNIO / NIOHTTP1, swift-testing not used here (project uses XCTest for these suites), NDJSON JSON-RPC 2.0 over stdio.

**Source of truth:** `docs/plugins-onresponse-design.md` (decisions R1–R8).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/IrisKit/Plugins/PluginRPC.swift` | Wire types | Add `OnResponseParams`, `OnResponseResult`, `Method.onResponse`. |
| `Sources/IrisKit/Plugins/PluginManifest.swift` | Manifest schema + validation | Add `HookEvent.onResponse`; reject `on_failure: block` for response hooks. |
| `Sources/IrisKit/Plugins/HookDispatcher.swift` | Hook chains | Add `PluginInvoking.onResponse` (default no-op); `responseChainBox` + `updateResponseChain`; `hasResponseHook`; `onResponse` fold. |
| `Sources/IrisKit/Plugins/PluginHost.swift` | Per-process IPC | Add `onResponse(_:timeout:)` (mirror of `onRequest`). |
| `Sources/IrisKit/Plugins/PluginHostManager.swift` | Chain publication | `republishChain` builds the response chain; new `onResponseChainChanged` callback; `shutdownAll` clears it. |
| `Sources/IrisKit/Proxy/UpstreamClient.swift` | Upstream stream | `stream(...)` gains `responseHeadHook` param, forwarded to the relay. |
| `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift` | Response relay | Run the head hook; queue parts during the hook; relay resolved head. |
| `Sources/IrisKit/Proxy/MITMHandler.swift` | Pipeline | Build `responseHeadHook` from the dispatcher; pass to `stream`. |
| `Sources/irisd/Daemon.swift` | Wiring | Wire `onResponseChainChanged → dispatcher.updateResponseChain`. |
| `examples/plugins/header-tagger/Sources/header-tagger/main.swift` | Example plugin | Handle `on_response`; inject `x-iris-tagged: 1`. |
| `examples/plugins/header-tagger/plugin.json` | Example manifest | Declare an `on_response` hook. |
| Tests (several) | Verification | Unit + integration + streaming-preservation. |

**Header semantics (reconciliation, see design §6):** `modify` **overlays** headers by name (`replaceOrAdd` semantics: unspecified headers preserved, no removal), aligning with the proven `onRequest` overlay (`HookDispatcher.swift:289-292`). The design doc is updated to match.

---

### Task 1: RPC types for `on_response`

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRPC.swift`
- Test: `Tests/IrisKitTests/PluginRPCTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PluginRPCTests`:

```swift
func testEncodeOnResponseRequestLine() throws {
    let params = PluginRPC.OnResponseParams(
        method: "POST", uri: "/v1/messages", host: "api.anthropic.com",
        status: 200, headers: [["content-type", "text/event-stream"]]
    )
    let line = try PluginRPC.encodeRequest(method: PluginRPC.Method.onResponse, params: params, id: 7)
    XCTAssertTrue(line.hasSuffix("\n"))
    XCTAssertFalse(line.dropLast().contains("\n"), "compact single-line NDJSON")
    XCTAssertTrue(line.contains("\"method\":\"on_response\""))
    XCTAssertTrue(line.contains("\"status\":200"))
}

func testDecodeOnResponseResultPassAndModify() throws {
    let passLine = #"{"jsonrpc":"2.0","id":7,"result":{"action":"pass"}}"#
    let pass = try PluginRPC.decodeResponse(passLine).result!.decode(as: PluginRPC.OnResponseResult.self)
    XCTAssertEqual(pass.action, .pass)
    XCTAssertNil(pass.headers)

    let modLine = #"{"jsonrpc":"2.0","id":7,"result":{"action":"modify","headers":[["x-iris-tagged","1"]]}}"#
    let mod = try PluginRPC.decodeResponse(modLine).result!.decode(as: PluginRPC.OnResponseResult.self)
    XCTAssertEqual(mod.action, .modify)
    XCTAssertEqual(mod.headers ?? [], [["x-iris-tagged", "1"]])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginRPCTests/testEncodeOnResponseRequestLine`
Expected: FAIL to compile — `OnResponseParams` / `Method.onResponse` not defined.

- [ ] **Step 3: Implement the RPC types**

In `PluginRPC.swift`, after `OnCompleteParams` (line 149), add:

```swift
    /// `on_response` params (daemon → plugin), request/response (reply expected).
    /// METADATA MODE: status + response headers only — never a response body
    /// (SPECS §7.2 bodies untouched). `uri` is the ORIGINAL request URI
    /// (placeholder-form), never a resolved secret (§6.1).
    public struct OnResponseParams: Codable, Sendable, Equatable {
        public let method: String
        public let uri: String
        public let host: String
        public let status: Int
        public let headers: [[String]]

        public init(method: String, uri: String, host: String, status: Int, headers: [[String]]) {
            self.method = method
            self.uri = uri
            self.host = host
            self.status = status
            self.headers = headers
        }
    }

    /// `on_response` result (plugin → daemon). Flat, action-driven.
    ///   pass   → (no other fields) — relay the head unchanged
    ///   modify → `headers` (overlaid by name onto the response head; status never modified)
    public struct OnResponseResult: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable { case pass, modify }
        public let action: Action
        public let headers: [[String]]?

        enum CodingKeys: String, CodingKey { case action, headers }

        public init(action: Action, headers: [[String]]? = nil) {
            self.action = action
            self.headers = headers
        }

        // Tolerant decode: only `action` is required.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.action = try c.decode(Action.self, forKey: .action)
            self.headers = try c.decodeIfPresent([[String]].self, forKey: .headers)
        }
    }
```

In the `Method` enum (line 153), add after `onComplete`:

```swift
        public static let onResponse = "on_response"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PluginRPCTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRPC.swift Tests/IrisKitTests/PluginRPCTests.swift
git commit -m "feat(plugins): on_response RPC types (params + result)"
```

---

### Task 2: `HookEvent.onResponse`, manifest validation, and chain plumbing

> This task adds the enum case. Because `PluginHostManager.republishChain` switches exhaustively on `HookEvent`, the manager + dispatcher + protocol plumbing must land together to keep `IrisKit` compiling. No response behavior yet (the fold is Task 3).

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift`
- Modify: `Sources/IrisKit/Plugins/HookDispatcher.swift`
- Modify: `Sources/IrisKit/Plugins/PluginHostManager.swift`
- Test: `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PluginManifestTests`:

```swift
func testDecodesOnResponseHook() throws {
    let json = #"""
    {"id":"p","name":"P","version":"1.0.0","api_version":1,"executable":"bin/p",
     "hooks":[{"event":"on_response","match":{"hosts":["api.anthropic.com"],"status":[200]},
               "on_failure":"skip","timeout_ms":1000}]}
    """#
    let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    try m.validate()
    XCTAssertEqual(m.hooks.first?.event, .onResponse)
    XCTAssertEqual(m.hooks.first?.match.status, [200])
}

func testResponseHookRejectsBlockFailureMode() throws {
    let json = #"""
    {"id":"p","name":"P","version":"1.0.0","api_version":1,"executable":"bin/p",
     "hooks":[{"event":"on_response","match":{},"on_failure":"block","timeout_ms":1000}]}
    """#
    let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    XCTAssertThrowsError(try m.validate()) { error in
        guard case PluginError.invalidManifest = error else {
            return XCTFail("expected .invalidManifest, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginManifestTests/testDecodesOnResponseHook`
Expected: FAIL — `on_response` not a known `HookEvent` (decode throws) and the package may not yet compile after Step 3a alone (the switch). Proceed through all of Step 3 before re-running.

- [ ] **Step 3a: Add the enum case + validation** (`PluginManifest.swift`)

In `HookEvent` (line 112), add after `onComplete`:

```swift
        case onResponse = "on_response"
```

In `validate()`, replace the hook loop (lines 82-86) with:

```swift
        for hook in hooks {
            guard hook.timeoutMs > 0 else {
                throw PluginError.invalidManifest("timeout_ms must be positive")
            }
            // A response already exists when an onResponse hook runs, so "block"
            // (fail the request closed) is meaningless — reject it (design R4).
            if hook.event == .onResponse, hook.onFailure == .block {
                throw PluginError.invalidManifest("on_response hooks do not support on_failure: block")
            }
        }
```

- [ ] **Step 3b: Add the protocol method + response chain** (`HookDispatcher.swift`)

In the `PluginInvoking` protocol (after the `onComplete` requirement, line 17), add:

```swift
    /// Runs the onResponse hook (metadata mode): observe/overlay response headers.
    /// Default is a no-op `pass` so conformers declaring no onResponse hook need
    /// not implement it.
    func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnResponseResult
```

In the `extension PluginInvoking` (after the `onComplete` default, line 22), add:

```swift
    public func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnResponseResult
    {
        .init(action: .pass)
    }
```

In `HookDispatcher`, after `completeChainBox` (line 63), add:

```swift
    private let responseChainBox = NIOLockedValueBox<[PluginChainEntry]>([])
```

After `updateCompleteChain` (line 78), add:

```swift
    /// Pushed by `PluginHostManager` after each reconcile (onResponse chain).
    public func updateResponseChain(_ chain: [PluginChainEntry]) {
        responseChainBox.withLockedValue { $0 = chain }
    }
```

- [ ] **Step 3c: Build + publish the response chain** (`PluginHostManager.swift`)

Add a stored callback. After `onCompleteChainChanged` (line 34):

```swift
    private let onResponseChainChanged: @Sendable ([PluginChainEntry]) -> Void
```

In `init`, after the `onCompleteChainChanged` parameter (line 52):

```swift
        onResponseChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
```

After `self.onCompleteChainChanged = onCompleteChainChanged` (line 62):

```swift
        self.onResponseChainChanged = onResponseChainChanged
```

In `shutdownAll`, after `onCompleteChainChanged([])` (line 124):

```swift
        onResponseChainChanged([])
```

In `republishChain`, add a `responseEntries` accumulator and handle the new case. Replace lines 242-256 with:

```swift
    private func republishChain(desired: [Plugin]) {
        var requestEntries: [PluginChainEntry] = []
        var responseEntries: [PluginChainEntry] = []
        var completeEntries: [PluginChainEntry] = []
        for plugin in desired.sorted(by: { $0.order < $1.order }) {
            guard let host = hosts[plugin.manifest.id] else { continue }
            for hook in plugin.manifest.hooks {
                let entry = PluginChainEntry(pluginId: plugin.manifest.id, invoker: host, hook: hook)
                switch hook.event {
                case .onRequest: requestEntries.append(entry)
                case .onResponse: responseEntries.append(entry)
                case .onComplete: completeEntries.append(entry)
                }
            }
        }
        onChainChanged(requestEntries)
        onResponseChainChanged(responseEntries)
        onCompleteChainChanged(completeEntries)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PluginManifestTests`
Expected: PASS. Also run `swift build` — module compiles (exhaustive switch satisfied; mocks use the protocol default).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Sources/IrisKit/Plugins/HookDispatcher.swift Sources/IrisKit/Plugins/PluginHostManager.swift Tests/IrisKitTests/Plugins/PluginManifestTests.swift
git commit -m "feat(plugins): HookEvent.onResponse + response chain plumbing"
```

---

### Task 3: Dispatcher `onResponse` fold + gating

**Files:**
- Modify: `Sources/IrisKit/Plugins/HookDispatcher.swift`
- Test: `Tests/IrisKitTests/Plugins/HookDispatcherTests.swift`

- [ ] **Step 1: Extend the mock and write failing tests**

In `HookDispatcherTests.swift`, extend `MockInvoker` (after the `onComplete` block, line 45) with an onResponse reply hook and a recorder:

```swift
    private var responseReply: (@Sendable (PluginRPC.OnResponseParams) async throws -> PluginRPC.OnResponseResult)?
    private var responseCalls = 0
    func setOnResponse(_ reply: @escaping @Sendable (PluginRPC.OnResponseParams) async throws -> PluginRPC.OnResponseResult) {
        responseReply = reply
    }
    func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnResponseResult
    {
        responseCalls += 1
        if let responseReply { return try await responseReply(params) }
        return .init(action: .pass)
    }
    var responseCallCount: Int { responseCalls }
```

Add a response-chain entry helper and tests:

```swift
    private func responseEntry(
        _ inv: any PluginInvoking,
        match: HookMatch = HookMatch(),
        onFailure: PluginHook.FailureMode = .skip
    ) -> PluginChainEntry {
        PluginChainEntry(
            pluginId: inv.id,
            invoker: inv,
            hook: PluginHook(event: .onResponse, match: match, mutates: true, onFailure: onFailure, timeoutMs: 1000)
        )
    }

    func testOnResponseModifyOverlaysHeader() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        await inv.setOnResponse { _ in .init(action: .modify, headers: [["x-iris-tagged", "1"]]) }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(inv, match: HookMatch(hosts: ["h"]))])
        let out = await d.onResponse(
            status: 200,
            headers: [("content-type", "text/event-stream")],
            method: "POST", uri: "/v1/messages", host: "h", contentType: "application/json"
        )
        XCTAssertEqual(out.first(where: { $0.0 == "x-iris-tagged" })?.1, "1")
        XCTAssertEqual(
            out.first(where: { $0.0 == "content-type" })?.1, "text/event-stream",
            "overlay preserves unspecified headers"
        )
    }

    func testOnResponsePassLeavesHeadersUntouched() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        await inv.setOnResponse { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(inv)])
        let out = await d.onResponse(
            status: 200, headers: [("a", "1")],
            method: "GET", uri: "/x", host: "h", contentType: nil
        )
        XCTAssertEqual(out.map { $0.0 }, ["a"])
        XCTAssertEqual(out.first?.1, "1")
    }

    func testOnResponseStatusGating() async {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        await inv.setOnResponse { _ in .init(action: .modify, headers: [["x", "1"]]) }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(inv, match: HookMatch(status: [500]))])
        let out = await d.onResponse(
            status: 200, headers: [("a", "1")],
            method: "GET", uri: "/x", host: "h", contentType: nil
        )
        let calls = await inv.responseCallCount
        XCTAssertEqual(calls, 0, "status [500] must not match a 200 response")
        XCTAssertEqual(out.map { $0.0 }, ["a"], "non-matching hook leaves headers unchanged")
    }

    func testOnResponseChainOrderFolds() async {
        let a = MockInvoker(id: "a") { _ in .init(action: .pass) }
        await a.setOnResponse { _ in .init(action: .modify, headers: [["x", "a"]]) }
        let b = MockInvoker(id: "b") { _ in .init(action: .pass) }
        await b.setOnResponse { p in
            let seen = p.headers.first(where: { $0[0] == "x" })?[1] ?? "?"
            return .init(action: .modify, headers: [["x", seen + "b"]])
        }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(a), responseEntry(b)])
        let out = await d.onResponse(
            status: 200, headers: [],
            method: "GET", uri: "/x", host: "h", contentType: nil
        )
        XCTAssertEqual(out.first(where: { $0.0 == "x" })?.1, "ab")
    }

    func testOnResponseSkipsFailingPlugin() async {
        struct Boom: Error {}
        let a = MockInvoker(id: "a") { _ in .init(action: .pass) }
        await a.setOnResponse { _ in throw Boom() }
        let b = MockInvoker(id: "b") { _ in .init(action: .pass) }
        await b.setOnResponse { _ in .init(action: .modify, headers: [["x-b", "1"]]) }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(a, onFailure: .skip), responseEntry(b)])
        let out = await d.onResponse(
            status: 200, headers: [],
            method: "GET", uri: "/x", host: "h", contentType: nil
        )
        XCTAssertEqual(out.first(where: { $0.0 == "x-b" })?.1, "1", "a throwing plugin is skipped; chain continues")
    }

    func testHasResponseHookPreGate() {
        let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
        let d = HookDispatcher()
        d.updateResponseChain([responseEntry(inv, match: HookMatch(hosts: ["api.anthropic.com"]))])
        XCTAssertTrue(d.hasResponseHook(method: "POST", uri: "/v1/messages", host: "api.anthropic.com", contentType: nil))
        XCTAssertFalse(d.hasResponseHook(method: "POST", uri: "/v1/messages", host: "other.com", contentType: nil))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookDispatcherTests/testOnResponseModifyOverlaysHeader`
Expected: FAIL to compile — `onResponse` / `hasResponseHook` not defined on `HookDispatcher`.

- [ ] **Step 3: Implement the fold + pre-gate** (`HookDispatcher.swift`)

After the `onComplete(...)` method (ends line 237), add:

```swift
    /// Cheap pre-gate (no IPC): true iff any onResponse hook matches the request's
    /// non-status conditions (host/method/path/contentType), known at request time.
    /// `MITMHandler` calls this to decide whether to install a response-head hook at
    /// all — a request with no applicable onResponse hook pays ZERO response-path cost.
    public func hasResponseHook(method: String, uri: String, host: String, contentType: String?) -> Bool {
        let chain = responseChainBox.withLockedValue { $0 }
        if chain.isEmpty { return false }
        let (path, _) = PlaceholderScanner.splitURI(uri)
        return chain.contains {
            $0.hook.match.matches(host: host, method: method, path: path, requestContentType: contentType)
        }
    }

    /// Runs the onResponse chain (metadata mode) at the response head. Returns the
    /// (possibly overlaid) response headers; the body is never seen or touched.
    /// Status-gates per plugin against the ACTUAL response status; folds headers
    /// through applicable plugins in chain order (each sees the prior overlay).
    /// A plugin error/timeout is SKIPPED (design R4) — current headers survive.
    public func onResponse(
        status: Int,
        headers: [(String, String)],
        method: String,
        uri: String,
        host: String,
        contentType: String?
    ) async -> [(String, String)] {
        let chain = responseChainBox.withLockedValue { $0 }
        if chain.isEmpty { return headers }
        let (path, _) = PlaceholderScanner.splitURI(uri)
        let applicable = chain.filter {
            $0.hook.match.matches(
                host: host, method: method, path: path, requestContentType: contentType, status: status
            )
        }
        if applicable.isEmpty { return headers }

        var current = headers
        for entry in applicable {
            let params = PluginRPC.OnResponseParams(
                method: method, uri: uri, host: host, status: status,
                headers: current.map { [$0.0, $0.1] }
            )
            let timeout = min(max(Double(entry.hook.timeoutMs) / 1000.0, 0.001), Self.maxHookTimeout)
            do {
                let result = try await entry.invoker.onResponse(params, timeout: timeout)
                if result.action == .modify, let pairs = result.headers {
                    current = Self.overlayResponseHeaders(pairs, onto: current)
                }
            } catch {
                // Response headers are upstream's (never carry an Iris secret value,
                // §6.1). onResponse only ever skips (design R4): keep current headers.
                logger.warning(
                    "plugin onResponse failed (skipped)",
                    metadata: ["id": "\(entry.pluginId)", "error": "\(error)"]
                )
                continue
            }
        }
        return current
    }

    /// Overlay by name (case-insensitive), mirroring `onRequest`'s `replaceOrAdd`:
    /// unspecified headers are preserved, no removal in v1. Order is stable —
    /// replaced headers keep position; new headers append.
    private static func overlayResponseHeaders(
        _ pairs: [[String]],
        onto current: [(String, String)]
    ) -> [(String, String)] {
        var result = current
        for p in pairs where p.count == 2 {
            if let idx = result.firstIndex(where: { $0.0.lowercased() == p[0].lowercased() }) {
                result[idx] = (p[0], p[1])
            } else {
                result.append((p[0], p[1]))
            }
        }
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookDispatcherTests`
Expected: PASS (existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Plugins/HookDispatcher.swift Tests/IrisKitTests/Plugins/HookDispatcherTests.swift
git commit -m "feat(plugins): HookDispatcher.onResponse fold + status gating + pre-gate"
```

---

### Task 4: `PluginHost.onResponse` IPC

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHost.swift`

> Proof is the real-subprocess E2E (Task 9): `onResponse` is a structural mirror of `onRequest` (`PluginHost.swift:211-219`), using the same `send` request/response machinery. No standalone unit test (the codebase tests the host path via integration, not in isolation).

- [ ] **Step 1: Implement the method**

In `PluginHost.swift`, after `onRequest(...)` (ends line 219), add:

```swift
    /// Sends one `on_response` and returns the typed result. Same request/response
    /// path as `onRequest`: throws `.timeout` on deadline, `.notRunning` if the
    /// process is gone, or the plugin's JSON-RPC error.
    public func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnResponseResult
    {
        guard started else { throw PluginHostError.notRunning }
        let response = try await send(method: PluginRPC.Method.onResponse, params: params, timeout: timeout)
        if let error = response.error { throw error }
        guard let result = response.result else { throw PluginHostError.malformedResponse }
        return try result.decode(as: PluginRPC.OnResponseResult.self)
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds clean. `PluginHost` now satisfies the `PluginInvoking.onResponse` requirement with a real impl (the protocol default no longer applies to it).

- [ ] **Step 3: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHost.swift
git commit -m "feat(plugins): PluginHost.onResponse IPC (mirror of onRequest)"
```

---

### Task 5: `UpstreamResponseRelay` head hook + `UpstreamClient.stream` param

**Files:**
- Modify: `Sources/IrisKit/Proxy/UpstreamClient.swift`
- Modify: `Sources/IrisKit/Proxy/UpstreamResponseRelay.swift`

> Proof is the integration tests (Tasks 7, 8). The relay has no standalone unit test in this codebase (it is integration-tested via `ProxyStreamingTests`). The key invariant: when `responseHeadHook == nil`, behavior is byte-for-byte identical to today.

- [ ] **Step 1: Thread the parameter through `UpstreamClient.stream`** (`UpstreamClient.swift`)

Add the parameter to `stream(...)`. After `headWritten: NIOLoopBoundBox<Bool>` (line 42) add:

```swift
        responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)? = nil
```

In the `channelInitializer` where the relay is constructed (lines 77-83), pass it through:

```swift
                            try sync.addHandler(
                                UpstreamResponseRelay(
                                    clientChannel: clientChannel,
                                    completion: completion,
                                    headWritten: headWritten,
                                    responseHeadHook: responseHeadHook
                                )
                            )
```

- [ ] **Step 2: Implement the relay head hook** (`UpstreamResponseRelay.swift`)

Add the stored hook + queue state. After `headWritten` (line 41):

```swift
    /// Optional metadata-mode onResponse hook. When set, the head is held until the
    /// hook resolves the (possibly header-overlaid) head; body/end parts that arrive
    /// during that timeout-bounded window are queued, then drained in order. nil →
    /// the head is relayed immediately (byte-for-byte the v1 path).
    private let responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)?
    private var headHookInFlight = false
    private var queuedParts: [HTTPClientResponsePart] = []
```

Update `init` to accept and store it (add the parameter after `headWritten`, assign it):

```swift
    init(
        clientChannel: Channel,
        completion: EventLoopPromise<StreamOutcome>,
        headWritten: NIOLoopBoundBox<Bool>,
        responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)? = nil
    ) {
        self.clientChannel = clientChannel
        self.completion = completion
        self.headWritten = headWritten
        self.responseHeadHook = responseHeadHook
    }
```

Replace `channelRead(context:data:)` (lines 57-86) with the hook-aware version + extracted relay helpers:

```swift
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        // Head hook pending: hold body/end until the resolved head is on the wire.
        if headHookInFlight {
            queuedParts.append(part)
            return
        }
        switch part {
        case .head(let head):
            guard let hook = responseHeadHook else {
                relayHead(head)
                return
            }
            // Hold the head; run the metadata-mode hook; relay the resolved head on
            // the EventLoop, then drain anything that arrived meanwhile.
            headHookInFlight = true
            hook(head).hop(to: clientChannel.eventLoop).whenComplete { [weak self] result in
                guard let self = self else { return }
                let resolved: HTTPResponseHead
                switch result {
                case .success(let h): resolved = h
                case .failure: resolved = head  // defensive: hook never fails (R4 skip)
                }
                self.relayHead(resolved)
                self.clientChannel.flush()  // off a read cycle → channelReadComplete won't flush
                self.headHookInFlight = false
                self.drainQueued()
            }
        case .body, .end:
            relayPart(part)
        }
    }

    /// Relays the response head to the client. Unflushed: when called on a read
    /// cycle, `channelReadComplete` coalesces the flush (the v1 behavior). The hook
    /// path flushes explicitly (it runs off a read cycle).
    private func relayHead(_ head: HTTPResponseHead) {
        status = Int(head.status.code)
        headWritten.value = true
        let outHead = HTTPResponseHead(version: head.version, status: head.status, headers: head.headers)
        clientChannel.write(HTTPServerResponsePart.head(outHead), promise: nil)
    }

    private func relayPart(_ part: HTTPClientResponsePart) {
        switch part {
        case .head(let head):
            relayHead(head)
        case .body(let buffer):
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        case .end(let trailers):
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success: self.finish(.success(StreamOutcome(statusCode: self.status)))
                case .failure(let error): self.finish(.failure(error))
                }
            }
        }
    }

    /// Drains parts queued during the head hook, in arrival order, then flushes.
    private func drainQueued() {
        let parts = queuedParts
        queuedParts.removeAll()
        for part in parts { relayPart(part) }
        clientChannel.flush()
    }
```

> Note: `relayHead`/`relayPart` are an extraction of the original inline `.head`/`.body`/`.end` writes — same operations, same comments preserved on `relayHead`. The only new behavior is the hook branch.

- [ ] **Step 3: Verify it compiles and the existing streaming suite is unchanged**

Run: `swift build && swift test --filter ProxyStreamingTests`
Expected: PASS — `ProxyStreamingTests` constructs `ProxyServer` with no onResponse chain, so every `responseHeadHook` is `nil` → the v1 path runs and all four streaming tests stay green (byte-for-byte relay, incremental delivery, 502, truncation).

- [ ] **Step 4: Commit**

```bash
git add Sources/IrisKit/Proxy/UpstreamClient.swift Sources/IrisKit/Proxy/UpstreamResponseRelay.swift
git commit -m "feat(proxy): response-head hook in UpstreamResponseRelay (nil = v1 path)"
```

---

### Task 6: `MITMHandler` builds the hook; daemon wiring

**Files:**
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift`
- Modify: `Sources/irisd/Daemon.swift`

> Proof is the integration tests (Tasks 7, 8).

- [ ] **Step 1: Build `responseHeadHook` and pass it to `stream`** (`MITMHandler.swift`)

In `forwardRequest`, after the `headWritten` declaration (line 128) add:

```swift
        // Pre-gate (design R6.a): build a response-head hook ONLY if an onResponse
        // plugin matches this request's request-time conditions. nil → the relay
        // runs the byte-for-byte v1 path (zero response-path cost).
        let dispatcher = server.hookDispatcher
        let responseHeadHook: (@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)?
        if dispatcher.hasResponseHook(
            method: originalMethod, uri: originalURI, host: host, contentType: originalContentType
        ) {
            responseHeadHook = { head in
                eventLoop.makeFutureWithTask { () async -> HTTPResponseHead in
                    let pairs = head.headers.map { ($0.name, $0.value) }
                    let modified = await dispatcher.onResponse(
                        status: Int(head.status.code),
                        headers: pairs,
                        method: originalMethod,
                        uri: originalURI,
                        host: host,
                        contentType: originalContentType
                    )
                    var h = HTTPHeaders()
                    for (n, v) in modified { h.add(name: n, value: v) }
                    var newHead = head
                    newHead.headers = h
                    return newHead
                }
            }
        } else {
            responseHeadHook = nil
        }
```

In the `default:` branch of the `.flatMap` (the `server.upstreamClient.stream(...)` call, lines 172-180), pass the hook:

```swift
                return server.upstreamClient.stream(
                    head: processed.head,
                    body: processed.body,
                    host: host,
                    port: server.configuration.upstreamPort,
                    to: channel,
                    on: eventLoop,
                    headWritten: headWritten,
                    responseHeadHook: responseHeadHook
                ).map { (processed, $0) }
```

> The synthetic branches (`pluginBlocked`/`pluginResponded`) intentionally do NOT pass the hook: a plugin-synthesized response never goes upstream, so there is no upstream response to observe (design §4).

- [ ] **Step 2: Wire the production callback** (`Daemon.swift`)

In the `PluginHostManager(...)` construction, after `onCompleteChainChanged:` (line 191) add:

```swift
            onResponseChainChanged: { [hookDispatcher] chain in hookDispatcher.updateResponseChain(chain) },
```

- [ ] **Step 3: Verify it compiles and all existing tests pass**

Run: `swift build && swift test`
Expected: builds clean; full suite green (no onResponse plugin installed → `hasResponseHook` is false everywhere → `nil` hook → existing behavior).

- [ ] **Step 4: Commit**

```bash
git add Sources/IrisKit/Proxy/MITMHandler.swift Sources/irisd/Daemon.swift
git commit -m "feat(proxy): wire onResponse hook into MITMHandler + daemon"
```

---

### Task 7: Integration E2E — header injected, body intact, gating (in-process invoker)

**Files:**
- Create: `Tests/IntegrationTests/PluginOnResponseE2ETests.swift`

> Mirrors `PluginOnCompleteE2ETests` harness (proxy + `MockUpstream` + in-process `PluginInvoking`). Proves the relay interception + dispatcher fold + that the overlaid header reaches the client AND the body is intact, plus request-time gating.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import IrisKit
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import XCTest

/// onResponse Task 7: a request through the live proxy fires the onResponse chain
/// at the response head; the plugin overlays a header that reaches the client while
/// the body relays unchanged; a non-matching request is untouched (gating).
final class PluginOnResponseE2ETests: XCTestCase {

    /// In-process onResponse plugin: overlays `x-iris-tagged: 1`. onRequest is a no-op.
    private struct TaggingInvoker: PluginInvoking {
        let id: String
        func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnRequestResult { .init(action: .pass) }
        func onResponse(_ params: PluginRPC.OnResponseParams, timeout: TimeInterval) async throws
            -> PluginRPC.OnResponseResult { .init(action: .modify, headers: [["x-iris-tagged", "1"]]) }
    }

    private struct Fixture {
        let proxy: ProxyServer
        let proxyPort: Int
        let proxyCANIO: NIOSSLCertificate
        let mock: MockUpstream
        func teardown() async { try? await proxy.stop(); try? await mock.stop() }
    }

    private func makeFixture() async throws -> Fixture {
        let secretStore = InMemorySecretStore()
        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()
        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1", listenPort: 0, allowedHosts: ["localhost"],
                upstreamPort: mock.port, upstreamTrustRoots: .certificates([mockCANIO]),
                onExfilAttempt: .blockOnly
            ),
            secretStore: secretStore,
            caManager: proxyCAManager,
            hookDispatcher: HookDispatcher()
        )
        let addr: SocketAddress
        do { addr = try await proxy.start() } catch { try? await mock.stop(); throw error }
        guard let proxyPort = addr.port else {
            try? await proxy.stop(); try? await mock.stop(); throw IntegrationTestError.bindFailed
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
        return Fixture(proxy: proxy, proxyPort: proxyPort, proxyCANIO: proxyCANIO, mock: mock)
    }

    private func responseHook(hosts: [String]) -> PluginHook {
        PluginHook(event: .onResponse, match: HookMatch(hosts: hosts), mutates: true, onFailure: .skip, timeoutMs: 1000)
    }

    func testResponseHeaderInjectedAndBodyIntact() async throws {
        let f = try await makeFixture()
        f.proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(pluginId: "tag", invoker: TaggingInvoker(id: "tag"), hook: responseHook(hosts: ["localhost"]))
        ])
        let resp = try await TestProxyClient().send(
            proxyHost: "127.0.0.1", proxyPort: f.proxyPort,
            targetHost: "localhost", targetPort: 443,
            method: .POST, path: "/v1/messages",
            headers: [("host", "localhost"), ("content-type", "application/json")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [f.proxyCANIO]
        )
        await f.teardown()
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.headers.first(name: "x-iris-tagged"), "1", "plugin-overlaid response header reaches the client")
        XCTAssertEqual(resp.body, Data("OK".utf8), "the upstream body is relayed unchanged")
    }

    func testNonMatchingRequestIsUntouched() async throws {
        let f = try await makeFixture()
        // Hook only matches host "other.com"; this request is to "localhost" → no hook.
        f.proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(pluginId: "tag", invoker: TaggingInvoker(id: "tag"), hook: responseHook(hosts: ["other.com"]))
        ])
        let resp = try await TestProxyClient().send(
            proxyHost: "127.0.0.1", proxyPort: f.proxyPort,
            targetHost: "localhost", targetPort: 443,
            method: .POST, path: "/v1/messages",
            headers: [("host", "localhost"), ("content-type", "application/json")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [f.proxyCANIO]
        )
        await f.teardown()
        XCTAssertEqual(resp.status, .ok)
        XCTAssertNil(resp.headers.first(name: "x-iris-tagged"), "non-matching request: no plugin header")
        XCTAssertEqual(resp.body, Data("OK".utf8))
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter PluginOnResponseE2ETests`
Expected: PASS. (If `testResponseHeaderInjectedAndBodyIntact` fails on the header, the relay hook wiring in Tasks 5/6 is wrong.)

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/PluginOnResponseE2ETests.swift
git commit -m "test(plugins): onResponse E2E — header injected, body intact, gating"
```

---

### Task 8: Streaming-preservation E2E — incremental delivery survives the head hook

**Files:**
- Modify: `Tests/IntegrationTests/PluginOnResponseE2ETests.swift`

> Mirrors `ProxyStreamingTests.testResponseChunksArriveIncrementally`. With an onResponse plugin active, chunk1 must STILL arrive before chunk2 is released — proving the head hook does not buffer the body (only the head is held, briefly).

- [ ] **Step 1: Write the failing test**

Add to `PluginOnResponseE2ETests` (the streaming mock helper + test). The harness mirrors `ProxyStreamingTests`:

```swift
    func testStreamingPreservedWithResponseHook() async throws {
        let proxyCA = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCA.ensureCA()
        let mockCA = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCA.ensureCA()

        // Barrier: the mock waits before sending chunk2 + end.
        let barrierGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? barrierGroup.syncShutdownGracefully() }
        let release = barrierGroup.next().makePromise(of: Void.self)

        let mock = try await MockUpstream.startStreaming(host: "localhost", caManager: mockCA) { _ in
            MockUpstream.StreamingResponsePlan(
                firstChunk: Data("AAAA".utf8),
                remainingChunks: [Data("BBBB".utf8)],
                releaseRest: release.futureResult
            )
        }
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxy = ProxyServer(
            configuration: .init(
                listenHost: "127.0.0.1", listenPort: 0, allowedHosts: ["localhost"],
                upstreamPort: mock.port, upstreamTrustRoots: .certificates([mockCANIO])
            ),
            secretStore: InMemorySecretStore(),
            caManager: proxyCA,
            hookDispatcher: HookDispatcher()
        )
        // Active onResponse plugin: overlays a header at the head.
        proxy.hookDispatcher.updateResponseChain([
            PluginChainEntry(pluginId: "tag", invoker: TaggingInvoker(id: "tag"), hook: responseHook(hosts: ["localhost"]))
        ])
        let addr = try await proxy.start()
        guard let proxyPort = addr.port else {
            try? await proxy.stop(); try? await mock.stop(); return XCTFail("proxy did not bind")
        }
        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)

        let resp = try await TestProxyClient().sendStreaming(
            proxyHost: "127.0.0.1", proxyPort: proxyPort,
            targetHost: "localhost", targetPort: 443,
            method: .POST, path: "/v1/messages",
            headers: [("host", "localhost")],
            body: Data(#"{"p":1}"#.utf8),
            trustingCAs: [proxyCANIO],
            streamTimeout: .seconds(3)
        )

        // PROOF: chunk1 arrives before chunk2 is released → the body is NOT buffered.
        try await resp.firstChunk.get()
        release.succeed(())

        var collected = Data()
        for await chunk in resp.bodyChunks { collected.append(chunk) }
        try? await proxy.stop()
        try? await mock.stop()

        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.headers.first(name: "x-iris-tagged"), "1", "header overlaid even on a streaming response")
        XCTAssertEqual(collected, Data("AAAABBBB".utf8), "body streamed intact")
    }
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter PluginOnResponseE2ETests/testStreamingPreservedWithResponseHook`
Expected: PASS. (Mutation discriminator: if Task 5 buffered the whole body instead of only holding the head, `resp.firstChunk.get()` would time out before `release` → FAIL.)

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/PluginOnResponseE2ETests.swift
git commit -m "test(plugins): onResponse preserves SSE streaming (head-only hold)"
```

---

### Task 9: `header-tagger` example gains an `on_response` hook + real-subprocess proof

**Files:**
- Modify: `examples/plugins/header-tagger/plugin.json`
- Modify: `examples/plugins/header-tagger/Sources/header-tagger/main.swift`
- Modify: `Tests/IntegrationTests/HeaderTaggerExampleTests.swift`

> The real-subprocess harness already exists in `HeaderTaggerExampleTests` (built on `PluginDispatchE2ETests`' real `PluginHostManager`). This task extends the plugin + adds an assertion that the REAL subprocess overlays a response header through the REAL relay, exercising `PluginHost.onResponse` (Task 4).

- [ ] **Step 1: Declare the `on_response` hook** (`plugin.json`)

Add to the `hooks` array (alongside the existing `on_request` hook):

```json
    { "event": "on_response", "match": { "hosts": ["localhost"] }, "on_failure": "skip", "timeout_ms": 1000 }
```

- [ ] **Step 2: Handle `on_response` in the plugin** (`main.swift`)

In the NDJSON request dispatch (where the existing `on_request` method is handled), add an `on_response` branch that replies with a `modify` overlaying one header. Mirror the existing `on_request` reply shape:

```swift
        case "on_response":
            // Metadata mode: overlay a tag header. Echo the daemon's request `id`.
            let result = #"{"action":"modify","headers":[["x-iris-tagged","1"]]}"#
            writeLine(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
```

> Match the file's existing helpers (`writeLine`, the `id` extraction, the method switch). If the file builds the reply with `Codable` rather than string interpolation, use the same `OnResponseResult`-shaped encodable instead — keep the file's style.

- [ ] **Step 3: Add the real-subprocess assertion** (`HeaderTaggerExampleTests.swift`)

Add a test that sends a request through the proxy with the real `header-tagger` installed and asserts the client sees `x-iris-tagged: 1` on the response. Reuse the file's existing fixture (real `PluginHostManager` + installed plugin); the new assertion is:

```swift
        XCTAssertEqual(resp.headers.first(name: "x-iris-tagged"), "1",
                       "real header-tagger subprocess overlays the response header via on_response")
```

> Mirror the existing onRequest assertion in this file for the send/setup; only the response-header assertion is new.

- [ ] **Step 4: Run the example suite**

Run: `swift test --filter HeaderTaggerExampleTests`
Expected: PASS — the real subprocess handles `on_response` and the header reaches the client.

- [ ] **Step 5: Commit**

```bash
git add examples/plugins/header-tagger Tests/IntegrationTests/HeaderTaggerExampleTests.swift
git commit -m "feat(plugins): header-tagger gains on_response hook + real-subprocess test"
```

---

### Task 10: Finalize — full suite, lint, design-doc sync, smoke checklist

**Files:**
- Modify: `docs/plugins-onresponse-design.md` (status → implemented)
- Modify: `SPECS.md` (§7.2/§7.3 clarification, R8)

- [ ] **Step 1: SPECS clarification (R8)**

In `SPECS.md §7.2`, after line 371 (`Response bodies are **never** scanned or modified.`) add:

```markdown
Plugins may, via the `onResponse` hook (metadata mode), observe the response status
line and **overlay response headers** before relay. Response **bodies** remain never
scanned, modified, or buffered (the relay forwards body parts part-by-part, §7.3).
```

- [ ] **Step 2: Full build, test, lint**

Run:
```bash
swift build -c release 2>&1 | tee /tmp/iris-build.log
swift test 2>&1 | tail -5
swift-format lint --strict --recursive Sources Tests
```
Expected: build 0 warnings; all tests pass; lint clean. Fix any `swift-format` findings (1 arg/line on multi-line calls, ≤120 cols).

- [ ] **Step 3: CI gate**

Push the branch; confirm the macos-15 CI (`build-test` + `xcode-build`) is green via the check-runs API (not `gh pr checks`).

- [ ] **Step 4: Commit + open PR**

```bash
git add docs/plugins-onresponse-design.md SPECS.md
git commit -m "docs(plugins): mark onResponse metadata mode implemented; clarify SPECS §7.2/§7.3"
```

Open the PR with this smoke-testing checklist (CLAUDE.md §8 — required for mergeability):

```markdown
## Smoke testing (ephemeral isolated daemon)
- [ ] A request matched by an onResponse plugin shows the overlaid response header at the client.
- [ ] The same request's SSE body still streams token-by-token (no buffering regression).
- [ ] A request NOT matched by any onResponse plugin is byte-for-byte unchanged (header + body).
- [ ] A plugin that times out on onResponse → the original response head is relayed (skip), response still succeeds.
- [ ] `iris plugin info <id>` lists the on_response hook; the Settings ▸ Plugins row renders it.
- [ ] A manifest declaring `on_response` with `on_failure: block` is rejected at install.
```

---

## Self-Review

**Spec coverage (design R1–R8):**
- R1 metadata-only → Tasks 1 (no body field in params), 5 (head-only hold). ✓
- R2 request/response transport → Task 1 (`encodeRequest`/result), Task 4 (`send`). ✓
- R3 headers-only, status read-only → Task 1 (result has no status), Task 3 (overlay only). ✓
- R4 skip-only, reject block → Task 2 (validation), Task 3 (catch→continue), Task 5 (failure→original head). ✓
- R5 no new capability → no capability code touched. ✓
- R6 two-stage gating → Task 3 (`hasResponseHook` + status filter), Task 6 (pre-gate → nil). ✓
- R7 separate ordered chain, fold, no short-circuit → Task 2 (chain), Task 3 (fold). ✓
- R8 SPECS clarification → Task 10. ✓

**Placeholder scan:** Task 9 Steps 2/3 say "mirror the existing pattern in this file" for `header-tagger`/`HeaderTaggerExampleTests` rather than reproducing files not read in full — this is deliberate (follow existing in-file conventions), with the concrete new lines shown. No `TBD`/`TODO`.

**Type consistency:** `OnResponseParams`/`OnResponseResult` (Task 1) used identically in Tasks 3/4/7/8/9; `updateResponseChain`/`hasResponseHook`/`onResponse` signatures match across dispatcher (Task 3) and MITMHandler (Task 6); `responseHeadHook` type `(@Sendable (HTTPResponseHead) -> EventLoopFuture<HTTPResponseHead>)?` identical in `stream` (Task 5) and the relay (Task 5) and MITMHandler (Task 6).

**Concurrency note:** if `swift build -c release` flags `HTTPResponseHead` Sendability on the `@Sendable` closure boundary, capture/return the header pairs (`[(String,String)]`) instead of the `HTTPResponseHead` and rebuild the head inside the relay; the relay is already `@unchecked Sendable`. Resolve at Task 5/6 if the compiler requires it.
