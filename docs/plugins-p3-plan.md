# Plugins P3 — onRequest Dispatch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make request traffic actually flow through enabled plugins — evaluate trigger conditions, dispatch the `onRequest` hook chain over the warm plugin processes, apply `pass`/`modify`/`block`/`respond`, and wire it into `MITMHandler` **before** Iris' own scan/substitution (security invariant §3), with value-free per-request plugin events.

**Architecture:** A new `HookDispatcher` (a `final class`, lock-box chain snapshot, async dispatch) is injected into `ProxyServer` next to `placeholderEngine`/`exfilRuleEngine`. `PluginHostManager` builds an ordered `[PluginChainEntry]` snapshot after every reconcile and pushes it to the dispatcher (so the hot path does a single lock read, zero IPC when no plugin matches). `MITMHandler.processRequest` calls the dispatcher right after the `bypass` check and before the existing strip/scan/substitute, which is extracted into a `scanAndSubstitute` helper. `block`/`respond` short-circuit the upstream forward with a synthetic response; everything that *does* go upstream still passes through the unchanged Iris scan. Plugin processes are reached through a `PluginInvoking` seam so the dispatcher is unit-testable with a mock.

**Tech Stack:** Swift 5.9+, SwiftPM, swift-nio / NIOHTTP1 (already an IrisKit dependency), XCTest, the existing NDJSON/JSON-RPC plugin transport (`PluginRPC`, `PluginHost`, `PluginHostManager` from P2b).

---

## Scope

**In scope (P3):**
- `onRequest` wire types in `PluginRPC` (`OnRequestParams`, `OnRequestResult`, `Body`, `Action`).
- Per-call IPC timeout on `PluginHost` + `PluginHost.onRequest` + `PluginInvoking` seam.
- `HookMatch` gating (exact host / methods / pathRegex / contentType), pure + unit-tested.
- `HookDispatcher` — chain snapshot, gating, dispatch, result application, `onFailure`.
- `PluginHostManager` chain-snapshot push to the dispatcher after reconcile.
- `Event.pluginId` + kinds `.pluginBlocked` / `.pluginResponded` (value-free).
- `MITMHandler` insertion + synthetic short-circuit for `block`/`respond`.
- `ProxyServer` + `Daemon` wiring.
- Integration tests proving the §3 invariant (modify forwarded; Iris substitution runs *after* plugin; a `skip`-failing plugin neither breaks the request nor bypasses the exfil scan).

**Out of scope (deferred, by decision):**
- §14 #6–10 registry/install hardening (transactional install, centralised id validation, symlink/size caps, list/info re-hash cache, capability-shape validation) → **separate "hardening" PR after P3** (user decision 2026-06-21).
- `onResponse` / `onComplete` hooks; config schema-driven forms (later phases, design §13).
- Plugins UI section (P4) and the shipped example plugin (P5).
- **Glob host matching** in `HookMatch.hosts`: the existing host logic (`allowed_hosts`, `ExfilRuleEngine`) is exact-only (SPECS §8.2 defers wildcards to v1.1). P3 matches hosts **exactly** (case-insensitive, port-stripped), consistent with the rest of the codebase. Glob is a documented follow-up, not a P3 gap.
- **Per-invocation "invoked/modified" events:** P3 emits terminal plugin events only (`.pluginBlocked`, `.pluginResponded`). A plugin that modifies a request and proceeds keeps the request's normal terminal event (`.substituted`/`.passThrough`/`.noMatch`); chain errors under `onFailure: skip` are logged value-free, not turned into events. This avoids one-event-per-plugin-per-request spam from an alive-but-flaky plugin. (Deviation from the handoff wishlist "invoqué/modifié"; rationale: noise + scope. Revisit if the UI needs a per-plugin timeline.)

---

## File Structure

**New files:**
- `Sources/IrisKit/Plugins/HookDispatcher.swift` — `HookDispatcher`, `PluginChainEntry`, `PluginInvoking`, outcome types, gating glue.
- `Tests/IrisKitTests/Plugins/HookMatchTests.swift` — pure gating tests.
- `Tests/IrisKitTests/Plugins/HookDispatcherTests.swift` — dispatch/chain/onFailure tests with a mock invoker.
- `Tests/IntegrationTests/PluginDispatchE2ETests.swift` — daemon-less `ProxyServer` + real plugin host, the §3 invariant proofs.

**Modified files:**
- `Sources/IrisKit/Plugins/PluginRPC.swift` — add `onRequest` method name + wire types.
- `Sources/IrisKit/Plugins/PluginHost.swift` — generalise `send` timeout, add `onRequest`, conform to `PluginInvoking`.
- `Sources/IrisKit/Plugins/PluginManifest.swift` — add `HookMatch.matches(...)`.
- `Sources/IrisKit/Plugins/PluginHostManager.swift` — build + push the chain snapshot after reconcile; inject `onChainChanged`.
- `Sources/IrisKit/Models/Event.swift` — add `pluginId` + 2 kinds.
- `Sources/IrisKit/Proxy/ProxyServer.swift` — add `hookDispatcher` (default empty).
- `Sources/IrisKit/Proxy/MITMHandler.swift` — insertion, `scanAndSubstitute` extraction, synthetic short-circuit, new outcomes + events.
- `Sources/irisd/Daemon.swift` — create dispatcher, inject into proxy, wire manager push.
- `Sources/iris-test-plugin/main.swift` — handle `onRequest` data-driven by an `x-test-action` header.
- `Tests/IrisKitTests/PluginRPCTests.swift` — wire-type round-trip tests.
- `Tests/IntegrationTests/PluginHostTests.swift` — `onRequest` round-trip + timeout against the fixture.

---

## Branch

```bash
git switch -c feat/plugins-p3-dispatch
```

Base = `main` (`7e784bd`, P2b). Conventional commits, one cohesive commit per task.

**Build/test/lint commands used throughout:**
- Build: `swift build`
- Targeted test: `swift test --filter <TestClass>[/<method>]`
- Full suite: `swift test`
- Lint (CI-exact, `--strict` turns camelCase warnings into errors): `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp`

> **Oracle reminder (memory):** SourceKit lags the cross-module compiler — a red squiggle "Cannot find type 'PluginChainEntry'" is not authoritative; `swift build` / `swift test` is. `Daemon` lives in module `irisd` → `@testable import irisd` for daemon tests; everything else is `import IrisKit`.

---

## Task 1: `PluginRPC` — onRequest wire types

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRPC.swift`
- Test: `Tests/IrisKitTests/PluginRPCTests.swift`

Wire shapes (design §8). Request (daemon → plugin):
```json
{ "method": "POST", "uri": "/v1/messages", "host": "api.anthropic.com",
  "headers": [["x-api-key","{{kc:anthropic_api_key}}"],["content-type","application/json"]],
  "body": { "encoding": "utf8", "data": "..." } }
```
Result (plugin → daemon), `action`-driven (flat shape; each field documents its applicable action):
```json
{ "action": "modify", "uri": "/v1/messages",
  "headers": [["x-iris-plugin","header-tagger"], ...],
  "body": { "encoding": "utf8", "data": "..." } }
```
`block` → `{ "action": "block", "reason": "..." }`. `respond` → `{ "action": "respond", "status": 418, "headers": [...], "body": {...} }`. `pass` → `{ "action": "pass" }`.

- [ ] **Step 1: Write failing tests** in `PluginRPCTests.swift`:

```swift
func testEncodeOnRequestParamsIsCompactSingleLine() throws {
    let params = PluginRPC.OnRequestParams(
        method: "POST", uri: "/v1/messages", host: "api.anthropic.com",
        headers: [["x-api-key", "{{kc:k}}"], ["content-type", "application/json"]],
        body: PluginRPC.Body(encoding: "utf8", data: "hello")
    )
    let line = try PluginRPC.encodeRequest(method: PluginRPC.Method.onRequest, params: params, id: 7)
    XCTAssertTrue(line.hasSuffix("\n"))
    XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "must be exactly one NDJSON line")
    XCTAssertTrue(line.contains("\"method\":\"on_request\"") || line.contains("on_request"))
}

func testDecodeOnRequestResultModify() throws {
    let json = #"{"action":"modify","uri":"/v1/x","headers":[["a","b"]],"body":{"encoding":"utf8","data":"z"}}"#
    let value = try JSONRPCCoder.makeDecoder().decode(PluginRPC.OnRequestResult.self, from: Data(json.utf8))
    XCTAssertEqual(value.action, .modify)
    XCTAssertEqual(value.uri, "/v1/x")
    XCTAssertEqual(value.headers ?? [], [["a", "b"]])
    XCTAssertEqual(value.body?.data, "z")
}

func testDecodeOnRequestResultBlockAndRespondAndPass() throws {
    let dec = JSONRPCCoder.makeDecoder()
    let block = try dec.decode(PluginRPC.OnRequestResult.self,
        from: Data(#"{"action":"block","reason":"nope"}"#.utf8))
    XCTAssertEqual(block.action, .block)
    XCTAssertEqual(block.reason, "nope")
    let respond = try dec.decode(PluginRPC.OnRequestResult.self,
        from: Data(#"{"action":"respond","status":418,"headers":[["x","y"]],"body":{"encoding":"utf8","data":"teapot"}}"#.utf8))
    XCTAssertEqual(respond.action, .respond)
    XCTAssertEqual(respond.status, 418)
    let pass = try dec.decode(PluginRPC.OnRequestResult.self, from: Data(#"{"action":"pass"}"#.utf8))
    XCTAssertEqual(pass.action, .pass)
    XCTAssertNil(pass.body)
}
```

- [ ] **Step 2: Run, verify FAIL** — `swift test --filter PluginRPCTests` → fails (types undefined).

- [ ] **Step 3: Implement** in `PluginRPC.swift`. Add to `enum Method`:
```swift
public static let onRequest = "on_request"
```
Add the types (inside `enum PluginRPC`):
```swift
/// Request/response body envelope. `encoding` is "utf8" for valid UTF-8 text,
/// "base64" for arbitrary bytes (newline-safe NDJSON, design §8).
public struct Body: Codable, Sendable, Equatable {
    public let encoding: String
    public let data: String
    public init(encoding: String, data: String) {
        self.encoding = encoding
        self.data = data
    }
}

/// `on_request` params (daemon → plugin). Headers are [[name, value], ...] —
/// the exact wire tuple shape from design §8. Carries placeholders only; the
/// plugin never sees a resolved secret (invariant §3).
public struct OnRequestParams: Codable, Sendable, Equatable {
    public let method: String
    public let uri: String
    public let host: String
    public let headers: [[String]]
    public let body: Body?
    public init(method: String, uri: String, host: String, headers: [[String]], body: Body?) {
        self.method = method
        self.uri = uri
        self.host = host
        self.headers = headers
        self.body = body
    }
}

/// `on_request` result (plugin → daemon). Flat, action-driven: which fields are
/// meaningful depends on `action`.
///   pass     → (no other fields)
///   modify   → `uri` (optional), `headers` (request headers, optional), `body` (optional)
///   block    → `reason` (optional)
///   respond  → `status` (required), `headers` (response headers, optional), `body` (optional)
public struct OnRequestResult: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case pass, modify, block, respond }
    public let action: Action
    public let uri: String?
    public let headers: [[String]]?
    public let body: Body?
    public let reason: String?
    public let status: Int?

    public init(
        action: Action, uri: String? = nil, headers: [[String]]? = nil,
        body: Body? = nil, reason: String? = nil, status: Int? = nil
    ) {
        self.action = action
        self.uri = uri
        self.headers = headers
        self.body = body
        self.reason = reason
        self.status = status
    }

    // Tolerant decode: only `action` is required.
    enum CodingKeys: String, CodingKey { case action, uri, headers, body, reason, status }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try c.decode(Action.self, forKey: .action)
        self.uri = try c.decodeIfPresent(String.self, forKey: .uri)
        self.headers = try c.decodeIfPresent([[String]].self, forKey: .headers)
        self.body = try c.decodeIfPresent(Body.self, forKey: .body)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.status = try c.decodeIfPresent(Int.self, forKey: .status)
    }
}
```

- [ ] **Step 4: Run, verify PASS** — `swift test --filter PluginRPCTests`.
- [ ] **Step 5: Lint** — `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` (exit 0).
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Plugins/PluginRPC.swift Tests/IrisKitTests/PluginRPCTests.swift
git commit -m "feat(plugins): P3 — onRequest IPC wire types"
```

---

## Task 2: `HookMatch.matches` — gating (pure)

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift`
- Test: `Tests/IrisKitTests/Plugins/HookMatchTests.swift` (new)

Gating runs **before any IPC** (design §4.3) so a request with no applicable plugin pays zero IPC cost. Pure function on `HookMatch`. Host = exact, case-insensitive, port-stripped (mirror `ExfilRuleEngine` normalisation; no glob — see Scope). `methods` empty = any; case-insensitive. `pathRegex` nil/empty = any; `NSRegularExpression`, matched against the path (no query). `contentType` nil = any; case-insensitive substring (a request `content-type` of `application/json; charset=utf-8` matches a hook `contentType` of `application/json`).

- [ ] **Step 1: Write failing tests** `HookMatchTests.swift`:
```swift
import XCTest
@testable import IrisKit

final class HookMatchTests: XCTestCase {
    private func ctx(host: String = "api.anthropic.com", method: String = "POST",
                     path: String = "/v1/messages", contentType: String? = "application/json") -> (String, String, String, String?) {
        (host, method, path, contentType)
    }

    func testEmptyMatchMatchesEverything() {
        let m = HookMatch()
        XCTAssertTrue(m.matches(host: "x.example", method: "GET", path: "/", contentType: nil))
    }
    func testHostExactCaseInsensitivePortStripped() {
        let m = HookMatch(hosts: ["api.anthropic.com"])
        XCTAssertTrue(m.matches(host: "API.Anthropic.com", method: "POST", path: "/v1", contentType: nil))
        XCTAssertTrue(m.matches(host: "api.anthropic.com:443", method: "POST", path: "/v1", contentType: nil))
        XCTAssertFalse(m.matches(host: "evil.com", method: "POST", path: "/v1", contentType: nil))
    }
    func testMethodFilter() {
        let m = HookMatch(methods: ["POST"])
        XCTAssertTrue(m.matches(host: "h", method: "post", path: "/", contentType: nil))
        XCTAssertFalse(m.matches(host: "h", method: "GET", path: "/", contentType: nil))
    }
    func testPathRegex() {
        let m = HookMatch(pathRegex: "^/v1/")
        XCTAssertTrue(m.matches(host: "h", method: "POST", path: "/v1/messages", contentType: nil))
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/v2/x", contentType: nil))
    }
    func testContentType() {
        let m = HookMatch(contentType: "application/json")
        XCTAssertTrue(m.matches(host: "h", method: "POST", path: "/", contentType: "application/json; charset=utf-8"))
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/", contentType: "text/plain"))
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/", contentType: nil))
    }
    func testAllConditionsAreAnded() {
        let m = HookMatch(hosts: ["h"], methods: ["POST"], pathRegex: "^/v1/", contentType: "application/json")
        XCTAssertTrue(m.matches(host: "h", method: "POST", path: "/v1/x", contentType: "application/json"))
        XCTAssertFalse(m.matches(host: "h", method: "GET", path: "/v1/x", contentType: "application/json"))
    }
    func testInvalidRegexNeverMatches() {
        let m = HookMatch(pathRegex: "[")  // invalid
        XCTAssertFalse(m.matches(host: "h", method: "POST", path: "/anything", contentType: nil))
    }
}
```

- [ ] **Step 2: Run, verify FAIL** — `swift test --filter HookMatchTests`.

- [ ] **Step 3: Implement** `HookMatch.matches` in `PluginManifest.swift` (extend the `HookMatch` struct):
```swift
extension HookMatch {
    /// True iff every declared condition matches. Empty/nil condition = wildcard.
    /// Host is exact, case-insensitive, port-stripped (SPECS §8.2; no glob in MVP).
    /// An unparseable `pathRegex` matches nothing (fail-closed gating).
    public func matches(host: String, method: String, path: String, contentType: String?) -> Bool {
        if !hosts.isEmpty {
            let normalized = Self.normalizeHost(host)
            guard hosts.contains(where: { Self.normalizeHost($0) == normalized }) else { return false }
        }
        if !methods.isEmpty {
            let m = method.lowercased()
            guard methods.contains(where: { $0.lowercased() == m }) else { return false }
        }
        if let pattern = pathRegex, !pattern.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            guard regex.firstMatch(in: path, range: range) != nil else { return false }
        }
        if let want = contentType, !want.isEmpty {
            guard let have = contentType.flatMap({ _ in contentType })?.lowercased(),
                have.contains(want.lowercased())
            else { return false }
        }
        return true
    }

    private static func normalizeHost(_ host: String) -> String {
        (host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host).lowercased()
    }
}
```
> NOTE on the `contentType` block: simplify to the actual request value, not a self-reference. Implement as:
> ```swift
> if let want = contentType, !want.isEmpty { ... }   // WRONG: shadows the request value
> ```
> Use distinct names — the hook's value is `self.contentType`, the request's is the parameter. Rename the parameter to `requestContentType` to avoid the clash:
```swift
public func matches(host: String, method: String, path: String, requestContentType: String?) -> Bool {
    // ... hosts/methods/pathRegex as above ...
    if let want = self.contentType, !want.isEmpty {
        guard let have = requestContentType?.lowercased(), have.contains(want.lowercased()) else { return false }
    }
    return true
}
```
> Update the test calls to use `requestContentType:`.

- [ ] **Step 4: Run, verify PASS** — `swift test --filter HookMatchTests`.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Tests/IrisKitTests/Plugins/HookMatchTests.swift
git commit -m "feat(plugins): P3 — HookMatch trigger-condition gating"
```

---

## Task 3: `PluginInvoking` seam + `PluginHost.onRequest` + per-call timeout + fixture

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHost.swift`
- Modify: `Sources/IrisKit/Plugins/HookDispatcher.swift` — **create** with just the `PluginInvoking` protocol for now (the dispatcher body lands in Task 4; keep this task's diff focused but the protocol must exist for `PluginHost` to conform).
- Modify: `Sources/iris-test-plugin/main.swift`
- Test: `Tests/IntegrationTests/PluginHostTests.swift`

The protocol seam (so the dispatcher is unit-testable with a mock):
```swift
// HookDispatcher.swift (Task 3 introduces only this; rest in Task 4)
import Foundation

/// The single capability the dispatcher needs from a plugin process: send one
/// `on_request` and get a typed result, with a per-call timeout. `PluginHost`
/// is the production conformer; tests inject a mock.
public protocol PluginInvoking: Sendable {
    var id: String { get }
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
}
```

- [ ] **Step 1: Write failing tests** in `PluginHostTests.swift` (extend the existing fixture-driven class). Add a helper that sends an `on_request` with an `x-test-action` header and asserts the action round-trips:
```swift
func testOnRequestPassRoundTrip() async throws {
    let scratch = try scratchDir(); defer { try? FileManager.default.removeItem(at: scratch) }
    let host = makeHost(scratch: scratch)
    try await host.start(); defer { Task { await host.shutdown() } }
    let result = try await host.onRequest(
        PluginRPC.OnRequestParams(method: "POST", uri: "/v1/x", host: "h",
            headers: [["x-test-action", "pass"]], body: nil),
        timeout: 2)
    XCTAssertEqual(result.action, .pass)
}

func testOnRequestModifyAddsHeader() async throws {
    let scratch = try scratchDir(); defer { try? FileManager.default.removeItem(at: scratch) }
    let host = makeHost(scratch: scratch)
    try await host.start()
    let result = try await host.onRequest(
        PluginRPC.OnRequestParams(method: "POST", uri: "/v1/x", host: "h",
            headers: [["x-test-action", "modify"]], body: nil),
        timeout: 2)
    XCTAssertEqual(result.action, .modify)
    XCTAssertTrue((result.headers ?? []).contains(["x-iris-plugin", "test"]))
    await host.shutdown()
}

func testOnRequestTimeoutThrows() async throws {
    let scratch = try scratchDir(); defer { try? FileManager.default.removeItem(at: scratch) }
    let host = makeHost(scratch: scratch)
    try await host.start()
    do {
        _ = try await host.onRequest(
            PluginRPC.OnRequestParams(method: "POST", uri: "/v1/x", host: "h",
                headers: [["x-test-action", "hang"]], body: nil),
            timeout: 0.3)
        XCTFail("expected timeout")
    } catch let error as PluginHostError {
        guard case .timeout = error else { return XCTFail("wrong error: \(error)") }
    }
    await host.shutdown()
}
```

- [ ] **Step 2: Run, verify FAIL** — `swift test --filter PluginHostTests` (no `onRequest` method; fixture ignores `on_request`).

- [ ] **Step 3a: Generalise `send` timeout in `PluginHost.swift`.** Change the signature and the timeout task to use the passed value:
```swift
private func send<P: Encodable>(method: String, params: P, timeout: TimeInterval) async throws -> JSONRPCResponse {
    let id = nextID
    nextID += 1
    let line = try PluginRPC.encodeRequest(method: method, params: params, id: id)
    let timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        await self?.failPending(id: id, error: PluginHostError.timeout(method))
    }
    defer { timeoutTask.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        do {
            guard let stdinHandle else { throw PluginHostError.notRunning }
            try stdinHandle.write(contentsOf: Data(line.utf8))
        } catch {
            pending[id] = nil
            continuation.resume(throwing: error)
        }
    }
}
```
Update the `initialize` call in `start()`:
```swift
let response = try await send(
    method: PluginRPC.Method.initialize,
    params: PluginRPC.InitializeParams(...),   // unchanged params
    timeout: timeouts.initialize
)
```

- [ ] **Step 3b: Add `onRequest`** (public) to `PluginHost`:
```swift
/// Sends one `on_request` and returns the typed result. Throws
/// `PluginHostError.timeout` on deadline, `PluginHostError.notRunning` if the
/// process is gone, or the plugin's JSON-RPC error if it reported one.
public func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
    -> PluginRPC.OnRequestResult
{
    guard started else { throw PluginHostError.notRunning }
    let response = try await send(method: PluginRPC.Method.onRequest, params: params, timeout: timeout)
    if let error = response.error { throw error }
    guard let result = response.result else { throw PluginHostError.initializeRejected }
    return try result.decode(as: PluginRPC.OnRequestResult.self)
}
```
> `PluginHostError.initializeRejected` is reused as the "no result" signal; if a clearer case is wanted add `case malformedResponse` to `PluginHostError` — optional, not required.

- [ ] **Step 3c: Conform `PluginHost` to `PluginInvoking`.** Add an extension (the `id`/`onRequest` already satisfy it):
```swift
extension PluginHost: PluginInvoking {}
```

- [ ] **Step 3d: Extend the fixture** `Sources/iris-test-plugin/main.swift`. In the `while let line` loop, handle `on_request` data-driven by the `x-test-action` header. Insert a `case "on_request":` before `default`:
```swift
case "on_request":
    let params = object["params"] as? [String: Any]
    let headers = (params?["headers"] as? [[String]]) ?? []
    let action = headers.first(where: { $0.count == 2 && $0[0].lowercased() == "x-test-action" })?[1] ?? "pass"
    switch action {
    case "modify":
        emitLine(["jsonrpc": "2.0", "id": id,
            "result": ["action": "modify", "headers": [["x-iris-plugin", "test"]]]])
    case "block":
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["action": "block", "reason": "test-block"]])
    case "respond":
        emitLine(["jsonrpc": "2.0", "id": id,
            "result": ["action": "respond", "status": 418,
                       "headers": [["x-from-plugin", "1"]],
                       "body": ["encoding": "utf8", "data": "teapot"]]])
    case "hang":
        continue  // never reply → drives the host-side timeout
    default:
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["action": "pass"]])
    }
```
> The fixture comment header should gain a line documenting the `x-test-action` request-header convention.

- [ ] **Step 4: Run, verify PASS** — `swift test --filter PluginHostTests`.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Plugins/PluginHost.swift Sources/IrisKit/Plugins/HookDispatcher.swift \
        Sources/iris-test-plugin/main.swift Tests/IntegrationTests/PluginHostTests.swift
git commit -m "feat(plugins): P3 — PluginHost.onRequest, per-call timeout, PluginInvoking seam"
```

---

## Task 4: `HookDispatcher` — chain, dispatch, result application, onFailure

**Files:**
- Modify: `Sources/IrisKit/Plugins/HookDispatcher.swift` (add the dispatcher body)
- Test: `Tests/IrisKitTests/Plugins/HookDispatcherTests.swift` (new)

`HookDispatcher` is a `final class` (Sendable via a lock box). It holds the current ordered chain snapshot, pushed by the manager (Task 5). The hot path: read snapshot under a lock; if empty → `.proceed` immediately (zero IPC); else gate each entry and dispatch the applicable ones in order; apply results; honour `onFailure`. Works in NIO request types (`HTTPRequestHead`/`ByteBuffer`) so `MITMHandler` plugs in directly; converts to/from the wire `Body` (utf8 if valid, else base64).

Outcome + chain-entry + invocation types (add to `HookDispatcher.swift`):
```swift
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// One running plugin + the `onRequest` hook it declared, in chain order. Built
/// by `PluginHostManager` after reconcile and pushed to the dispatcher.
public struct PluginChainEntry: Sendable {
    public let pluginId: String
    public let invoker: any PluginInvoking
    public let hook: PluginHook  // event == .onRequest
    public init(pluginId: String, invoker: any PluginInvoking, hook: PluginHook) {
        self.pluginId = pluginId
        self.invoker = invoker
        self.hook = hook
    }
}

public enum HookOutcome: Sendable {
    /// Continue to Iris scan/substitution with this (possibly modified) request.
    case proceed(head: HTTPRequestHead, body: ByteBuffer?)
    /// A plugin blocked the request; no upstream forward.
    case block(pluginId: String, reason: String?)
    /// A plugin returned a synthetic response; no upstream forward.
    case respond(pluginId: String, status: Int, headers: [(String, String)], body: ByteBuffer?)
}
```

The dispatcher:
```swift
public final class HookDispatcher: Sendable {
    /// Iris-side ceiling on a hook's declared timeout (design §4.5 "plafonné par Iris").
    public static let maxHookTimeout: TimeInterval = 5.0
    /// Cap on a `respond` body the dispatcher will relay (mirror MITM scan cap).
    static let maxRespondBodyBytes = 4 * 1024 * 1024

    private let chainBox = NIOLockedValueBox<[PluginChainEntry]>([])
    private let logger: Logger

    public init(logger: Logger = Logger(label: "io.iris.plugins.dispatch")) {
        self.logger = logger
    }

    /// Pushed by `PluginHostManager` after each reconcile. Cheap lock write.
    public func updateChain(_ chain: [PluginChainEntry]) {
        chainBox.withLockedValue { $0 = chain }
    }

    /// Runs the onRequest chain. `host`/`path` are the gating inputs; `head`/`body`
    /// are the request as decrypted (placeholders present, pre-Iris-scan).
    public func onRequest(head: HTTPRequestHead, body: ByteBuffer?, host: String) async -> HookOutcome {
        let chain = chainBox.withLockedValue { $0 }
        if chain.isEmpty { return .proceed(head: head, body: body) }

        let (path, _) = PlaceholderScanner.splitURI(head.uri)
        let method = head.method.rawValue
        let contentType = head.headers.first(name: "content-type")
        // Gate first — zero IPC if nothing applies (design §4.3).
        let applicable = chain.filter {
            $0.hook.match.matches(host: host, method: method, path: path, requestContentType: contentType)
        }
        if applicable.isEmpty { return .proceed(head: head, body: body) }

        var curHead = head
        var curBody = body
        for entry in applicable {
            let params = Self.makeParams(head: curHead, body: curBody, host: host)
            let timeout = min(Double(entry.hook.timeoutMs) / 1000.0, Self.maxHookTimeout)
            do {
                let result = try await entry.invoker.onRequest(params, timeout: timeout)
                switch result.action {
                case .pass:
                    continue
                case .modify:
                    (curHead, curBody) = Self.applyModify(result, to: curHead, body: curBody)
                case .block:
                    return .block(pluginId: entry.pluginId, reason: result.reason)
                case .respond:
                    let status = result.status ?? 200
                    let headers = (result.headers ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
                    let rbody = Self.decodeBody(result.body, cap: Self.maxRespondBodyBytes)
                    return .respond(pluginId: entry.pluginId, status: status, headers: headers, body: rbody)
                }
            } catch {
                // Value-free: id + failure mode only, never request payload (§6.1).
                logger.warning("plugin onRequest failed",
                    metadata: ["id": "\(entry.pluginId)", "on_failure": "\(entry.hook.onFailure)", "error": "\(error)"])
                switch entry.hook.onFailure {
                case .skip: continue
                case .block: return .block(pluginId: entry.pluginId, reason: "plugin error (fail-closed)")
                }
            }
        }
        return .proceed(head: curHead, body: curBody)
    }

    // MARK: - Wire conversion

    static func makeParams(head: HTTPRequestHead, body: ByteBuffer?, host: String) -> PluginRPC.OnRequestParams {
        let headers = head.headers.map { [$0.name, $0.value] }
        return PluginRPC.OnRequestParams(
            method: head.method.rawValue, uri: head.uri, host: host,
            headers: headers, body: encodeBody(body))
    }

    static func encodeBody(_ body: ByteBuffer?) -> PluginRPC.Body? {
        guard let body, body.readableBytes > 0 else { return nil }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) {
            return PluginRPC.Body(encoding: "utf8", data: utf8)
        }
        return PluginRPC.Body(encoding: "base64", data: data.base64EncodedString())
    }

    static func decodeBody(_ body: PluginRPC.Body?, cap: Int) -> ByteBuffer? {
        guard let body else { return nil }
        let data: Data?
        switch body.encoding.lowercased() {
        case "base64": data = Data(base64Encoded: body.data)
        default: data = Data(body.data.utf8)
        }
        guard let bytes = data, bytes.count <= cap else { return nil }
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        return buf
    }

    static func applyModify(_ result: PluginRPC.OnRequestResult, to head: HTTPRequestHead, body: ByteBuffer?)
        -> (HTTPRequestHead, ByteBuffer?)
    {
        var newHead = head
        if let uri = result.uri { newHead.uri = uri }
        if let pairs = result.headers {
            var h = HTTPHeaders()
            for p in pairs where p.count == 2 { h.add(name: p[0], value: p[1]) }
            newHead.headers = h
        }
        var newBody = body
        if let b = result.body, let decoded = decodeBody(b, cap: maxRespondBodyBytes) {
            newBody = decoded
            if newHead.headers.contains(name: "content-length") {
                newHead.headers.replaceOrAdd(name: "content-length", value: "\(decoded.readableBytes)")
            }
        }
        return (newHead, newBody)
    }
}
```
> Concurrency note: `PluginChainEntry` holds `any PluginInvoking` (Sendable) and `PluginHook` (Sendable) → `[PluginChainEntry]` is Sendable, safe in the lock box. `HTTPRequestHead`/`ByteBuffer` are value types passed across the `await` to the actor (`PluginHost`) — fine. Build with `swift build` as the oracle if SourceKit complains about `NIOCore`/`NIOHTTP1` imports (IrisKit already links NIO/NIOHTTP1).

- [ ] **Step 1: Write failing tests** `HookDispatcherTests.swift` with a mock invoker:
```swift
import Logging
import NIOCore
import NIOHTTP1
import XCTest
@testable import IrisKit

private actor MockInvoker: PluginInvoking {
    let id: String
    private let reply: @Sendable (PluginRPC.OnRequestParams) async throws -> PluginRPC.OnRequestResult
    private(set) var calls = 0
    init(id: String, reply: @escaping @Sendable (PluginRPC.OnRequestParams) async throws -> PluginRPC.OnRequestResult) {
        self.id = id; self.reply = reply
    }
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws -> PluginRPC.OnRequestResult {
        calls += 1
        return try await reply(params)
    }
    var callCount: Int { calls }
}

final class HookDispatcherTests: XCTestCase {
    private func head(method: String = "POST", uri: String = "/v1/messages",
                      headers: [(String, String)] = [("content-type", "application/json")]) -> HTTPRequestHead {
        var h = HTTPHeaders(); for (n, v) in headers { h.add(name: n, value: v) }
        return HTTPRequestHead(version: .http1_1, method: .init(rawValue: method), uri: uri, headers: h)
    }
    private func entry(_ inv: any PluginInvoking, match: HookMatch = HookMatch(),
                       onFailure: PluginHook.FailureMode = .skip, mutates: Bool = true) -> PluginChainEntry {
        PluginChainEntry(pluginId: inv.id, invoker: inv,
            hook: PluginHook(event: .onRequest, match: match, mutates: mutates, onFailure: onFailure, timeoutMs: 1000))
    }

    func testEmptyChainProceedsUnchanged() async {
        let d = HookDispatcher()
        let h = head()
        let out = await d.onRequest(head: h, body: nil, host: "api.anthropic.com")
        guard case .proceed(let rh, let rb) = out else { return XCTFail() }
        XCTAssertEqual(rh.uri, h.uri); XCTAssertNil(rb)
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
        let d = HookDispatcher(); d.updateChain([entry(inv)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail() }
        XCTAssertEqual(rh.headers.first(name: "x-iris-plugin"), "t")
    }

    func testBlockShortCircuits() async {
        let a = MockInvoker(id: "a") { _ in .init(action: .block, reason: "no") }
        let b = MockInvoker(id: "b") { _ in .init(action: .modify) }
        let d = HookDispatcher(); d.updateChain([entry(a), entry(b)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .block(let pid, let reason) = out else { return XCTFail() }
        XCTAssertEqual(pid, "a"); XCTAssertEqual(reason, "no")
        let bCalls = await b.callCount
        XCTAssertEqual(bCalls, 0, "chain short-circuits on block")
    }

    func testRespondShortCircuits() async {
        let inv = MockInvoker(id: "p") { _ in
            .init(action: .respond, body: .init(encoding: "utf8", data: "teapot"), status: 418)
        }
        let d = HookDispatcher(); d.updateChain([entry(inv)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .respond(let pid, let status, _, let body) = out else { return XCTFail() }
        XCTAssertEqual(pid, "p"); XCTAssertEqual(status, 418)
        XCTAssertEqual(body?.getString(at: 0, length: body?.readableBytes ?? 0), "teapot")
    }

    func testOnFailureSkipContinues() async {
        struct Boom: Error {}
        let a = MockInvoker(id: "a") { _ in throw Boom() }
        let b = MockInvoker(id: "b") { _ in .init(action: .modify, headers: [["x-b", "1"]]) }
        let d = HookDispatcher(); d.updateChain([entry(a, onFailure: .skip), entry(b)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail() }
        XCTAssertEqual(rh.headers.first(name: "x-b"), "1", "skip continues the chain")
    }

    func testOnFailureBlockFailsClosed() async {
        struct Boom: Error {}
        let a = MockInvoker(id: "a") { _ in throw Boom() }
        let d = HookDispatcher(); d.updateChain([entry(a, onFailure: .block)])
        let out = await d.onRequest(head: head(), body: nil, host: "h")
        guard case .block(let pid, _) = out else { return XCTFail() }
        XCTAssertEqual(pid, "a")
    }

    func testChainOrderIsRespected() async {
        // a sets x to "1", b appends -> proves order a then b.
        let a = MockInvoker(id: "a") { _ in .init(action: .modify, headers: [["x", "a"]]) }
        let b = MockInvoker(id: "b") { p in
            let seen = p.headers.first(where: { $0[0] == "x" })?[1] ?? "?"
            return .init(action: .modify, headers: [["x", seen + "b"]])
        }
        let d = HookDispatcher(); d.updateChain([entry(a), entry(b)])
        let out = await d.onRequest(head: head(headers: []), body: nil, host: "h")
        guard case .proceed(let rh, _) = out else { return XCTFail() }
        XCTAssertEqual(rh.headers.first(name: "x"), "ab")
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** the dispatcher body (code above).
- [ ] **Step 4: Run, verify PASS** — `swift test --filter HookDispatcherTests`.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Plugins/HookDispatcher.swift Tests/IrisKitTests/Plugins/HookDispatcherTests.swift
git commit -m "feat(plugins): P3 — HookDispatcher (gating, chain, onFailure, result application)"
```

---

## Task 5: `PluginHostManager` — build + push the chain snapshot

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHostManager.swift`
- Test: `Tests/IntegrationTests/PluginHostManagerTests.swift`

After every `performReconcile`, build the ordered `[PluginChainEntry]` from the currently-running hosts intersected with the desired plugins (which carry order + manifest hooks), keeping only `onRequest` hooks, and push it via an injected `onChainChanged` closure. Inject the closure in `init` (mirrors `emitSystemAlert`).

- [ ] **Step 1: Write failing test** in `PluginHostManagerTests.swift`. (Mirror the existing manager test harness — it already boots real hosts against the fixture via an installed launcher. Reuse that setup; assert the pushed chain.)
```swift
func testReconcilePushesOnRequestChain() async throws {
    // ... existing harness: install + enable one fixture plugin whose manifest
    // declares an onRequest hook (hosts: ["h"]) ...
    let pushed = NIOLockedValueBox<[PluginChainEntry]>([])
    let manager = makeManager(onChainChanged: { chain in pushed.withLockedValue { $0 = chain } })
    await manager.startEnabled()
    let chain = pushed.withLockedValue { $0 }
    XCTAssertEqual(chain.map(\.pluginId), ["<installed id>"])
    XCTAssertEqual(chain.first?.hook.event, .onRequest)
    await manager.shutdownAll()
    XCTAssertTrue(pushed.withLockedValue { $0 }.isEmpty, "shutdown clears the chain")
}
```
> The fixture's `plugin.json` used by the manager harness must declare at least one `onRequest` hook. If the existing P2b manifest fixture has no hooks, add a hook to it (`{"event":"on_request","match":{"hosts":["h"]},"mutates":true,"on_failure":"skip","timeout_ms":1000}`). `PluginManifest.validate()` already requires ≥1 hook, so the P2b fixture must already declare one — reuse it.

- [ ] **Step 2: Run, verify FAIL** — `swift test --filter PluginHostManagerTests/testReconcilePushesOnRequestChain`.

- [ ] **Step 3: Implement.** Add to `PluginHostManager`:
  - Stored `private let onChainChanged: @Sendable ([PluginChainEntry]) -> Void` + init param (default `{ _ in }` to keep existing call sites compiling).
  - In `performReconcile`, capture the `desired` list (already fetched) keyed by id, then after the start/stop loops rebuild + push the chain:
```swift
private func performReconcile() async {
    let desired = await desiredPlugins()
    let desiredIDs = Set(desired.map(\.manifest.id))
    let idsToStop = hosts.keys.filter { !desiredIDs.contains($0) }
    for id in idsToStop { if let h = hosts[id] { await h.shutdown(); hosts[id] = nil } }
    for plugin in desired
    where hosts[plugin.manifest.id] == nil && !restarting.contains(plugin.manifest.id) {
        await startHost(for: plugin)
    }
    pushChain(desired: desired)
}

/// Ordered chain of running hosts × their onRequest hooks (design §4.4: order
/// persisted in config). One entry per (host, onRequest hook).
private func pushChain(desired: [Plugin]) {
    var entries: [PluginChainEntry] = []
    for plugin in desired.sorted(by: { $0.order < $1.order }) {
        guard let host = hosts[plugin.manifest.id] else { continue }  // not running yet/failed
        for hook in plugin.manifest.hooks where hook.event == .onRequest {
            entries.append(PluginChainEntry(pluginId: plugin.manifest.id, invoker: host, hook: hook))
        }
    }
    onChainChanged(entries)
}
```
  - In `shutdownAll`, push an empty chain after clearing hosts:
```swift
public func shutdownAll() async {
    shuttingDown = true
    for (_, host) in hosts { await host.shutdown() }
    hosts.removeAll()
    onChainChanged([])
}
```
  - In `handleUnexpectedExit`, after a restart (or auto-disable), re-push so the chain reflects reality. Simplest: at the end of `handleUnexpectedExit` and after `startHost` in the restart path, call `pushChain(desired: await desiredPlugins())`. Auto-disable returns early — push an empty-for-that-id chain there too (rebuild from current `hosts`):
```swift
// after auto-disable `return` block, before returning:
pushChain(desired: await desiredPlugins())
```
> Keep it correct, not clever: any path that changes `hosts` should re-push. The cheap way is a single `private func republishChain() async { pushChain(desired: await desiredPlugins()) }` called at the tail of `performReconcile`, after a successful restart `startHost`, and after auto-disable.

- [ ] **Step 4: Run, verify PASS.** Run the full manager suite (`swift test --filter PluginHostManagerTests`) to confirm no regression.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Plugins/PluginHostManager.swift Tests/IntegrationTests/PluginHostManagerTests.swift
git commit -m "feat(plugins): P3 — manager builds and pushes the onRequest chain snapshot"
```

---

## Task 6: `Event` — `pluginId` + terminal plugin kinds

**Files:**
- Modify: `Sources/IrisKit/Models/Event.swift`
- Test: `Tests/IrisKitTests/` (find the existing Event tests file; if none, add `EventPluginTests.swift`)

- [ ] **Step 1: Write failing test** (redaction + round-trip):
```swift
func testPluginBlockedEventCarriesIdNoPayload() throws {
    let e = Event(timestamp: Date(), kind: .pluginBlocked, host: "api.anthropic.com",
                  method: "POST", path: "/v1/messages", statusCode: 403, durationMs: 5, pluginId: "org.example.tagger")
    let data = try JSONRPCCoder.makeEncoder().encode(e)
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(json.contains("\"plugin_id\""))
    XCTAssertTrue(json.contains("org.example.tagger"))
    let back = try JSONRPCCoder.makeDecoder().decode(Event.self, from: data)
    XCTAssertEqual(back.kind, .pluginBlocked)
    XCTAssertEqual(back.pluginId, "org.example.tagger")
}
func testOlderEventWithoutPluginIdStillDecodes() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000000","timestamp":"2026-06-21T00:00:00Z","kind":"substituted","host":"h","method":"POST","path":"/","substituted_secrets":[]}"#
    let e = try JSONRPCCoder.makeDecoder().decode(Event.self, from: Data(json.utf8))
    XCTAssertNil(e.pluginId)
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement.** In `Event.swift`:
  - Add to `Kind`: `case pluginBlocked` / `case pluginResponded` (with a doc-comment: terminal plugin outcomes; the request was not forwarded upstream).
  - Add stored `public let pluginId: String?`.
  - Add `case pluginId = "plugin_id"` to `CodingKeys`.
  - Add `pluginId: String? = nil` to the memberwise `init` (last param, defaulted → existing call sites unaffected).
  - `Event` has no custom `init(from:)` today (it relies on synthesised Codable). Adding an optional property keeps decoding tolerant **only if** synthesised decode treats a missing key as `nil` — it does for `Optional`. So `testOlderEventWithoutPluginIdStillDecodes` passes without a custom initializer. (No `init(from:)` needed.)

- [ ] **Step 4: Run, verify PASS** — `swift test --filter <EventTests>`.
- [ ] **Step 5: Build the whole tree** — `swift build` — to surface any exhaustiveness `switch` over `Event.Kind` that now misses the new cases (e.g. UI/CLI rendering). Fix each non-exhaustive switch by handling the two new kinds (render as e.g. "plugin blocked"/"plugin responded"). Search: `grep -rn "case .substituted\|case .exfilBlocked\|switch.*kind" Sources`.
- [ ] **Step 6: Lint + Commit**
```bash
git add Sources/IrisKit/Models/Event.swift Tests/IrisKitTests/...
git commit -m "feat(plugins): P3 — Event pluginId + terminal plugin kinds (value-free)"
```

---

## Task 7: `ProxyServer` injection + `MITMHandler` insertion + synthetic short-circuit

**Files:**
- Modify: `Sources/IrisKit/Proxy/ProxyServer.swift`
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift`
- Test: `Tests/IrisKitTests/Proxy/` (a focused MITM unit test) + `Tests/IntegrationTests/PluginDispatchE2ETests.swift` (Task 8 adds the full E2E; this task adds the MITM-level behavior with the dispatcher driven by a mock chain)

### 7a. `ProxyServer` field

- [ ] **Step 1:** Add a stored `let hookDispatcher: HookDispatcher` and an init param defaulted so all existing call sites/tests keep compiling with a no-op empty dispatcher:
```swift
public let hookDispatcher: HookDispatcher
// in init signature, after `group`:
hookDispatcher: HookDispatcher? = nil,
// in init body:
self.hookDispatcher = hookDispatcher ?? HookDispatcher(logger: logger)
```

### 7b. `MITMHandler` — call dispatcher, extract scan, short-circuit

- [ ] **Step 2: Write failing tests** — a MITM-level test that drives `processRequest` (or the public forward path) with a `ProxyServer` whose dispatcher chain is set to a mock that blocks / responds / modifies, and asserts the resulting `ProcessedRequest.Outcome`. If `processRequest` is `private static`, add an internal test seam OR test through the public proxy with a `TestProxyClient` (preferred — matches `ProxyEndToEndTests`). Given the existing private static design, prefer the E2E approach; put the concrete assertions in Task 8 and keep this task's test minimal:
```swift
// Tests/IrisKitTests/Proxy/MITMPluginOutcomeTests.swift — exercises makeEvent mapping
func testMakeEventMapsPluginBlocked() {
    // Build a ProcessedRequest.Outcome.pluginBlocked and assert makeEvent yields kind .pluginBlocked + pluginId.
    // (makeEvent is private static; if not reachable, fold this assertion into the E2E test in Task 8.)
}
```
> If reaching `makeEvent`/`processRequest` requires loosening access (`private` → `internal`), do it minimally with a `// test seam` comment, OR rely solely on the Task 8 E2E. Do not widen API beyond what the test needs.

- [ ] **Step 3a: Add the new outcomes** to `MITMHandler.ProcessedRequest.Outcome`:
```swift
case pluginBlocked(pluginId: String, reason: String?)
case pluginResponded(pluginId: String, status: Int, headers: [(String, String)], body: ByteBuffer?)
```

- [ ] **Step 3b: Extract** the existing strip/scan/substitute (current lines ~231–417, everything after the `bypass` early-return) into a new `private static func scanAndSubstitute(head:body:evaluator:engine:secretStore:logger:host:) async throws -> ProcessedRequest`. Mechanical move; no logic change.

- [ ] **Step 3c: Rewrite** `processRequest` to insert the dispatcher between `bypass` and `scanAndSubstitute`:
```swift
private static func processRequest(
    head: HTTPRequestHead, body: ByteBuffer?, dispatcher: HookDispatcher,
    evaluator: ExfilRuleEngine, engine: PlaceholderEngine, secretStore: any SecretStore,
    logger: Logger, host: String, bypass: Bool
) async throws -> ProcessedRequest {
    if bypass { return makeBypassedRequest(head: head, body: body) }
    // P3: onRequest plugin chain runs BEFORE Iris scan/substitution (invariant §3:
    // whatever proceeds upstream is still scanned by scanAndSubstitute below).
    switch await dispatcher.onRequest(head: head, body: body, host: host) {
    case .block(let pid, let reason):
        return ProcessedRequest(head: head, body: body, outcome: .pluginBlocked(pluginId: pid, reason: reason))
    case .respond(let pid, let status, let headers, let rbody):
        return ProcessedRequest(head: head, body: body,
            outcome: .pluginResponded(pluginId: pid, status: status, headers: headers, body: rbody))
    case .proceed(let h, let b):
        return try await scanAndSubstitute(head: h, body: b, evaluator: evaluator,
            engine: engine, secretStore: secretStore, logger: logger, host: host)
    }
}
```
Update the single caller in `forwardRequest` (the `makeFutureWithTask` closure) to pass `dispatcher: server.hookDispatcher`.

- [ ] **Step 3d: Short-circuit the upstream forward** in `forwardRequest`'s `.flatMap`. Replace the body so plugin short-circuits write a synthetic response instead of streaming upstream:
```swift
}.flatMap { processed -> EventLoopFuture<(ProcessedRequest, StreamOutcome)> in
    switch processed.outcome {
    case .pluginBlocked:
        return Self.writeSynthetic(status: 403, headers: [], body: nil,
            to: channel, on: eventLoop, headWritten: headWritten).map { (processed, $0) }
    case .pluginResponded(_, let status, let headers, let body):
        return Self.writeSynthetic(status: status, headers: headers, body: body,
            to: channel, on: eventLoop, headWritten: headWritten).map { (processed, $0) }
    default:
        return server.upstreamClient.stream(
            head: processed.head, body: processed.body, host: host,
            port: server.configuration.upstreamPort, to: channel, on: eventLoop,
            headWritten: headWritten
        ).map { (processed, $0) }
    }
}
```
Add the helper:
```swift
/// Writes a plugin-supplied synthetic response (block/respond) to the client and
/// resolves with its status. Mirrors `writeBadGateway`: routes via `Channel.write`
/// (thread-safe), sets `headWritten` so the failure path doesn't double-write.
private static func writeSynthetic(
    status: Int, headers: [(String, String)], body: ByteBuffer?,
    to channel: Channel, on eventLoop: EventLoop, headWritten: NIOLoopBoundBox<Bool>
) -> EventLoopFuture<StreamOutcome> {
    var h = HTTPHeaders()
    for (n, v) in headers where n.lowercased() != "content-length" && n.lowercased() != "transfer-encoding" {
        h.add(name: n, value: v)
    }
    h.replaceOrAdd(name: "content-length", value: "\(body?.readableBytes ?? 0)")
    let respHead = HTTPResponseHead(version: .http1_1,
        status: HTTPResponseStatus(statusCode: status), headers: h)
    headWritten.value = true
    channel.write(HTTPServerResponsePart.head(respHead), promise: nil)
    if let body, body.readableBytes > 0 {
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
    }
    let promise = eventLoop.makePromise(of: StreamOutcome.self)
    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
        promise.succeed(StreamOutcome(statusCode: status))
    }
    return promise.futureResult
}
```
> The `.whenComplete` that emits the event + closes is unchanged: it now also covers the synthetic path (success → `makeEvent` over the plugin outcome → close).

- [ ] **Step 3e: Map events** in `makeEvent` — add the two cases:
```swift
case .pluginBlocked(let pluginId, _):
    return Event(timestamp: startTime, kind: .pluginBlocked, host: host, method: originalMethod,
        path: originalURI, statusCode: status, durationMs: duration, pluginId: pluginId)
case .pluginResponded(let pluginId, _, _, _):
    return Event(timestamp: startTime, kind: .pluginResponded, host: host, method: originalMethod,
        path: originalURI, statusCode: status, durationMs: duration, pluginId: pluginId)
```
And handle the two new cases in `logOutcome` (log value-free at info/warning; no secret, no payload):
```swift
case .pluginBlocked(let pluginId, _):
    server.logger.info("plugin blocked request", metadata: ["host": "\(host)", "plugin": "\(pluginId)"])
case .pluginResponded(let pluginId, let st, _, _):
    server.logger.info("plugin responded synthetically",
        metadata: ["host": "\(host)", "plugin": "\(pluginId)", "status": "\(st)"])
```

- [ ] **Step 4: Build + run** the full proxy suites to prove zero regression on the empty-dispatcher path:
`swift test --filter ProxyEndToEndTests` and `swift test --filter MITM`.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit**
```bash
git add Sources/IrisKit/Proxy/ProxyServer.swift Sources/IrisKit/Proxy/MITMHandler.swift Tests/IrisKitTests/Proxy/
git commit -m "feat(plugins): P3 — MITMHandler runs onRequest chain before scan, synthetic short-circuit"
```

---

## Task 8: Daemon wiring + E2E invariant proofs

**Files:**
- Modify: `Sources/irisd/Daemon.swift`
- Test: `Tests/IntegrationTests/PluginDispatchE2ETests.swift` (new); `Tests/IntegrationTests/PluginDaemonWiringTests.swift` (extend)

### 8a. Daemon wiring

- [ ] **Step 1:** In `Daemon.init`, create the dispatcher before the proxy, inject it into `ProxyServer`, and wire the manager's `onChainChanged` to push into it.
  - `ProxyServer` is constructed early; create `let hookDispatcher = HookDispatcher(logger: logger)` before it and pass `hookDispatcher: hookDispatcher`.
  - In the `PluginHostManager(...)` call add:
```swift
onChainChanged: { [hookDispatcher] chain in hookDispatcher.updateChain(chain) },
```
  - `updateChain` is synchronous; the closure is `@Sendable ([PluginChainEntry]) -> Void`. No `await`.

- [ ] **Step 2: Build** — `swift build`. The dispatcher must be created before `ProxyServer.init`; confirm ordering compiles.

### 8b. E2E invariant proofs (design §12)

These mirror `ProxyEndToEndTests` (real `ProxyServer` + `MockUpstream` + `TestProxyClient`), but install a real plugin host into the dispatcher chain. Use the fixture (`ExecutableLocator.testPlugin`) via a `PluginHost` started directly, then `proxy.hookDispatcher.updateChain([PluginChainEntry(... invoker: host, hook: onRequestHook)])`. Drive the action with an `x-test-action` request header from the client.

- [ ] **Step 3: Write tests** `PluginDispatchE2ETests.swift`:
```swift
func testPluginModifyThenIrisSubstitutionBothApply() async throws {
    // secret scoped to localhost; client sends x-api-key: {{kc:NAME}} + x-test-action: modify.
    // Assert MockUpstream received BOTH: the plugin's x-iris-plugin: test header
    // AND the substituted real secret value in x-api-key — proving the plugin ran
    // first (modify) and Iris substitution ran AFTER (invariant §3).
}

func testPluginBlockReturns403AndNoUpstream() async throws {
    // x-test-action: block. Assert client gets 403 and MockUpstream received NOTHING.
}

func testPluginRespondReturnsSyntheticAndNoUpstream() async throws {
    // x-test-action: respond. Assert client gets 418 + body "teapot", MockUpstream received nothing.
}

func testFailingSkipPluginDoesNotBypassExfilScan() async throws {
    // Plugin hook onFailure=skip, action=hang with a short hook timeout → plugin errors/skipped.
    // Client sends a body that the exfil engine must BLOCK (e.g. a known secret in a
    // disallowed location). Assert the request is still blocked by Iris (exfil scan ran
    // after the skipped plugin) — proving a failing plugin never bypasses Iris security.
}
```
> Build each test's `PluginChainEntry` with a `PluginHook(event: .onRequest, match: HookMatch(hosts: ["localhost"]), onFailure: ..., timeoutMs: ...)`. Start the host with a canonical scratch dir (reuse `PluginHostTests.scratchDir()` pattern). Tear down host + proxy + mock in `defer`.

- [ ] **Step 4: Extend `PluginDaemonWiringTests`** with one test booting a real `Daemon` (rooted under `/tmp/iris-xxx-<hex>` to dodge the `sun_path` ~104-char limit — memory lesson P2b a), installing+enabling a fixture plugin with an onRequest hook, and asserting the dispatcher chain is non-empty after boot (`daemon.proxyForTesting.hookDispatcher` — add a tiny test accessor if needed, or assert via an end-to-end request). Keep it minimal; the behavior is already covered by 8b — this proves the wiring path.

- [ ] **Step 5: Run** — `swift test --filter PluginDispatchE2ETests` and `swift test --filter PluginDaemonWiringTests`. Then the **full suite**: `swift test` (expect 596 baseline + the P3 additions, 0 failures).
- [ ] **Step 6: Lint** (CI-exact) — `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp`.
- [ ] **Step 7: Commit**
```bash
git add Sources/irisd/Daemon.swift Tests/IntegrationTests/PluginDispatchE2ETests.swift Tests/IntegrationTests/PluginDaemonWiringTests.swift
git commit -m "feat(plugins): P3 — wire dispatcher into daemon; E2E §3-invariant proofs"
```

---

## Self-Review (run after the last task, before opening the PR)

**1. Spec coverage** (design §4/§8/§9/§12):
- §4.1 insertion after bypass, before scan → Task 7 (`processRequest`). ✅
- §4.3 gating before IPC, zero cost when no match → Task 4 (`applicable.isEmpty` short-circuit) + Task 2. ✅
- §4.4 ordered chain, block/respond short-circuit → Task 4 + Task 5 (order) ✅
- §4.5 onFailure skip/block + per-hook timeout capped → Task 4. ✅
- §8 onRequest wire shape (pass/modify/block/respond) → Task 1. ✅
- §9.2 Event pluginId + plugin kinds (value-free) → Task 6 + Task 7 (makeEvent). ✅
- §3 invariant (Iris scan always runs on what proceeds; failing plugin doesn't bypass) → Task 7 (`.proceed`→`scanAndSubstitute`) + Task 8 E2E. ✅
- §12 tests (modify forwarded; substitution after; skip-fail doesn't break/bypass; no payload in events) → Task 8 + Task 6. ✅

**2. Placeholder scan:** Confirm no `TODO`/`add validation`/`similar to`/"write tests for the above" remain. The `contentType` self-reference bug in Task 2 Step 3 is called out and the corrected `requestContentType:` signature is the one to implement.

**3. Type consistency:** `OnRequestParams`/`OnRequestResult`/`Body`/`Action` (Task 1) ↔ used in `PluginHost.onRequest` (Task 3) ↔ `HookDispatcher` (Task 4) ↔ fixture (Task 3). `PluginChainEntry`(pluginId, invoker, hook) (Task 4) ↔ built in manager `pushChain` (Task 5). `HookOutcome` (Task 4) ↔ consumed in `processRequest` (Task 7). `HookMatch.matches(host:method:path:requestContentType:)` (Task 2) ↔ called in dispatcher (Task 4). `Event.pluginId` + `.pluginBlocked`/`.pluginResponded` (Task 6) ↔ `makeEvent` (Task 7). `ProcessedRequest.Outcome.pluginBlocked/pluginResponded` (Task 7) ↔ `makeEvent`/`logOutcome`/`flatMap` (Task 7). All consistent.

**4. Security invariant re-check:** The plugin only ever receives placeholders (`makeParams` runs on the pre-substitution head/body; substitution is in `scanAndSubstitute`, after `.proceed`). `block`/`respond` never forward upstream, so no secret leaves; a synthetic body returned to the local client tool only ever echoes placeholders it already holds. Events carry `pluginId` + status only, never request/response payloads. ✅

---

## PR smoke-test checklist (paste into the PR body, design §12 + CLAUDE.md §8)

- [ ] `swift build` clean.
- [ ] `swift test` green (baseline 596 + P3 additions, 0 failures).
- [ ] `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` exit 0.
- [ ] `onRequest` wire types round-trip for all 4 actions (PluginRPCTests).
- [ ] Gating: match/no-match per condition; invalid regex never matches (HookMatchTests).
- [ ] Dispatcher: empty/no-match → zero IPC; modify; block short-circuits; respond short-circuits; onFailure skip vs block; chain order (HookDispatcherTests).
- [ ] Host: onRequest round-trip (pass/modify) + per-call timeout against the fixture (PluginHostTests).
- [ ] Manager pushes the ordered onRequest chain after reconcile; shutdown clears it (PluginHostManagerTests).
- [ ] E2E: plugin `modify` + Iris substitution **both** reach upstream, in that order (invariant §3).
- [ ] E2E: `block` → 403, nothing reaches upstream.
- [ ] E2E: `respond` → synthetic status/body to client, nothing reaches upstream.
- [ ] E2E: a `skip`-failing plugin does **not** break the request and does **not** bypass the exfil scan.
- [ ] Event: `.pluginBlocked`/`.pluginResponded` carry `pluginId`, no payload; older events without `plugin_id` still decode.
- [ ] All existing proxy tests pass unchanged with the default empty dispatcher (no behavior change when no plugins).

---

## Notes / lessons to carry (memory)

- **CI strict-concurrency:** the `{ [weak self] … Task { await self?… } }` pattern in a synchronous closure errors on the (older) CI macos-15 compiler though it passes locally. If any new closure here spawns a `Task`, use `guard let self else { return }` before the `Task` (rebind to a strong `let`). The dispatcher avoids this (it's a `final class`, not an actor) and the manager's `onChainChanged` is a plain sync call.
- **Oracle:** `swift build`/`swift test`, not SourceKit. CI macos-15 is the final judge for concurrency diagnostics.
- **No `Thread.sleep`** in proxy/daemon; test harnesses may poll (bounded) — that rule targets production paths only.
- **Gemini:** one round of review on this repo; once the initial block is handled, the Gemini step is closed (no re-poll after a fix push).
