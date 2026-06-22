# Plugins `onComplete` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `onComplete` plugin hook — a fire-and-forget, read-only observability callback fired at the end of every proxied request, delivering HTTP-level metadata (method/uri/host/status/durationMs) to matched plugins.

**Architecture:** Extend the existing `onRequest` plumbing (P1→P5). A new `on_complete` NDJSON **notification** (no reply) is dispatched from `MITMHandler.forwardRequest`'s `.whenComplete` block via a **detached `Task`**, so a slow/dead plugin can never delay or break the response. A second, homogeneous `onComplete` chain lives beside the `onRequest` chain in `HookDispatcher`; gating reuses `HookMatch` plus a new `status` condition, evaluated before any IPC. The response streaming path (Phase 2.x) and SPECS §7.2 are untouched — `onComplete` never sees a body or header.

**Tech Stack:** Swift 5.9+, swift-nio (NIOHTTP1/NIOCore), swift-log, XCTest. NDJSON/JSON-RPC 2.0 over stdio. Reference design: `docs/plugins-oncomplete-design.md`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/IrisKit/Plugins/PluginManifest.swift` | Manifest + `HookEvent` + `HookMatch` gating | Add `HookEvent.onComplete`; add `HookMatch.status` + status-aware `matches`. |
| `Sources/IrisKit/Plugins/PluginRPC.swift` | Wire types | Add `OnCompleteParams`, `Method.onComplete`, `encodeNotification(method:params:)`. |
| `Sources/IrisKit/Plugins/HookDispatcher.swift` | Gating + dispatch | Add `onComplete` to `PluginInvoking` (+ default no-op); add `completeChainBox` + `updateCompleteChain`; add `func onComplete(...)`. |
| `Sources/IrisKit/Plugins/PluginHost.swift` | Warm process IPC | Add `func onComplete(_:)` (notification write). |
| `Sources/IrisKit/Plugins/PluginHostManager.swift` | Chain publication | Build + publish the `onComplete` chain (new `onCompleteChainChanged` callback). |
| `Sources/irisd/Daemon.swift` | Wiring | Wire `onCompleteChainChanged → dispatcher.updateCompleteChain`. |
| `Sources/IrisKit/Proxy/MITMHandler.swift` | Insertion point | Capture `originalContentType`; dispatch `onComplete` in both `.whenComplete` branches. |
| `examples/plugins/header-tagger/Sources/header-tagger/main.swift` | Example plugin | Handle `on_complete` (append a line to scratch). |
| `examples/plugins/header-tagger/plugin.json` | Example manifest | Declare an `on_complete` hook + `filesystem: ["scratch"]`. |
| `Tests/IrisKitTests/Plugins/HookMatchTests.swift` | Unit | Status gating tests. |
| `Tests/IrisKitTests/Plugins/PluginManifestTests.swift` | Unit | `on_complete` decode test. |
| `Tests/IrisKitTests/PluginRPCTests.swift` | Unit | OnComplete encode tests. |
| `Tests/IrisKitTests/Plugins/HookDispatcherTests.swift` | Unit | Dispatcher `onComplete` gating/dispatch tests. |
| `Tests/IntegrationTests/PluginHostManagerTests.swift` | Integration | onComplete chain published. |
| `Tests/IntegrationTests/HeaderTaggerExampleTests.swift` | Integration | Real `on_complete` delivery to the example plugin. |
| `Tests/IntegrationTests/PluginOnCompleteE2ETests.swift` (new) | Integration | Proxy-level: a request fires `onComplete` with the right status, non-blocking. |

---

## Task 1: `HookMatch.status` + status-aware `matches`

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift` (struct `HookMatch`, lines 153–247)
- Test: `Tests/IrisKitTests/Plugins/HookMatchTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `HookMatchTests.swift` (inside the `final class HookMatchTests`):

```swift
func testStatusIgnoredWhenNotProvided() {
    // An onRequest evaluation passes no status: a status condition must be skipped,
    // never fail the match (there is no response status at request time).
    let m = HookMatch(status: [200])
    XCTAssertTrue(m.matches(host: "h", method: "POST", path: "/", requestContentType: nil))
}

func testStatusMatchesWhenProvided() {
    let m = HookMatch(status: [500, 502, 503])
    XCTAssertTrue(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil, status: 502))
    XCTAssertFalse(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil, status: 200))
}

func testEmptyStatusListIsWildcard() {
    let m = HookMatch(status: [])
    XCTAssertTrue(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil, status: 418))
}

func testStatusZeroSentinelCanBeTargeted() {
    // status=0 is the upstream-failure sentinel (design C5); a hook can target it.
    let m = HookMatch(status: [0])
    XCTAssertTrue(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil, status: 0))
    XCTAssertFalse(m.matches(host: "h", method: "GET", path: "/", requestContentType: nil, status: 200))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookMatchTests`
Expected: FAIL — `HookMatch` has no `status:` initializer parameter and `matches` has no `status:` argument (compile error).

- [ ] **Step 3: Add the `status` stored property + CodingKey + inits**

In `HookMatch` (PluginManifest.swift), add the property after `contentType`:

```swift
    public let contentType: String?
    /// Response status codes to match (onComplete/onResponse only). nil/empty =
    /// wildcard. Ignored for onRequest (no response status exists at request time).
    public let status: [Int]?
```

Extend `CodingKeys`:

```swift
    enum CodingKeys: String, CodingKey {
        case hosts, methods
        case pathRegex = "path_regex"
        case contentType = "content_type"
        case status
    }
```

Extend the memberwise `init` (add `status` param, defaulted):

```swift
    public init(
        hosts: [String] = [],
        methods: [String] = [],
        pathRegex: String? = nil,
        contentType: String? = nil,
        status: [Int]? = nil
    ) {
        self.hosts = hosts
        self.methods = methods
        self.pathRegex = pathRegex
        self.contentType = contentType
        self.status = status
    }
```

Extend the tolerant `init(from:)`:

```swift
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        self.status = try c.decodeIfPresent([Int].self, forKey: .status)
```

- [ ] **Step 4: Add the `status` parameter to `matches`**

In the `extension HookMatch`, change the `matches` signature and add the status check at the end (before `return true`):

```swift
    public func matches(
        host: String,
        method: String,
        path: String,
        requestContentType: String?,
        status: Int? = nil
    ) -> Bool {
```

…and just before the final `return true`:

```swift
        // Status is response-only: enforce only when the hook declares it AND a
        // status is supplied (onComplete). At onRequest `status` is nil → skipped.
        if let declared = self.status, !declared.isEmpty, let actual = status {
            guard declared.contains(actual) else { return false }
        }
        return true
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HookMatchTests`
Expected: PASS (all existing HookMatch tests + the 4 new ones; the `status: Int? = nil` default keeps the existing `onRequest` call site in `HookDispatcher.onRequest` compiling).

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Tests/IrisKitTests/Plugins/HookMatchTests.swift
git commit -m "feat(plugins): HookMatch.status condition (response-only gating)"
```

---

## Task 2: `HookEvent.onComplete`

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift` (enum `HookEvent`, lines 112–115)
- Test: `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `PluginManifestTests.swift` (inside the test class):

```swift
func testDecodesOnCompleteHook() throws {
    let json = """
    {"id":"org.x.sink","name":"Sink","version":"1.0.0","api_version":1,
     "executable":"bin/sink",
     "hooks":[{"event":"on_complete","match":{"hosts":["api.anthropic.com"],"status":[500,502]},
               "timeout_ms":1000}]}
    """
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    try manifest.validate()
    XCTAssertEqual(manifest.hooks.count, 1)
    XCTAssertEqual(manifest.hooks[0].event, .onComplete)
    XCTAssertEqual(manifest.hooks[0].match.status, [500, 502])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginManifestTests.testDecodesOnCompleteHook`
Expected: FAIL — `on_complete` is not a known `HookEvent` raw value → decode throws.

- [ ] **Step 3: Add the enum case**

In `PluginHook.HookEvent` (PluginManifest.swift):

```swift
    public enum HookEvent: String, Codable, Sendable, CaseIterable {
        case onRequest = "on_request"
        case onComplete = "on_complete"
        // on_response reserved for a later phase (PR 2).
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PluginManifestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Tests/IrisKitTests/Plugins/PluginManifestTests.swift
git commit -m "feat(plugins): HookEvent.onComplete manifest case"
```

---

## Task 3: `PluginRPC` — `OnCompleteParams`, `Method.onComplete`, `encodeNotification(params:)`

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRPC.swift`
- Test: `Tests/IrisKitTests/PluginRPCTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PluginRPCTests.swift`:

```swift
func testEncodeOnCompleteNotificationHasNoIdAndCarriesParams() throws {
    let params = PluginRPC.OnCompleteParams(
        method: "POST", uri: "/v1/messages", host: "api.anthropic.com",
        status: 200, durationMs: 1342
    )
    let line = try PluginRPC.encodeNotification(method: PluginRPC.Method.onComplete, params: params)
    XCTAssertTrue(line.hasSuffix("\n"))
    XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
    XCTAssertFalse(line.contains("\"id\""), "a notification carries no id")
    XCTAssertTrue(line.contains("\"method\":\"on_complete\""))
    XCTAssertTrue(line.contains("\"status\":200"))
    XCTAssertTrue(line.contains("\"duration_ms\":1342"))
    XCTAssertTrue(line.contains("\"host\":\"api.anthropic.com\""))
}

func testOnCompleteParamsRoundTrips() throws {
    let params = PluginRPC.OnCompleteParams(
        method: "GET", uri: "/v1/x", host: "h", status: 0, durationMs: 5
    )
    let data = try JSONEncoder().encode(params)
    let back = try JSONDecoder().decode(PluginRPC.OnCompleteParams.self, from: data)
    XCTAssertEqual(back, params)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginRPCTests`
Expected: FAIL — `OnCompleteParams`, `Method.onComplete`, and `encodeNotification(method:params:)` do not exist (compile error).

- [ ] **Step 3: Add `OnCompleteParams`**

In `enum PluginRPC`, after `OnRequestResult` (before `enum Method`):

```swift
    /// `on_complete` params (daemon → plugin), a NOTIFICATION (no reply expected).
    /// HTTP-level metadata only — never a body or header (invariant §7.2/§6.1). The
    /// `uri` is the ORIGINAL request URI (placeholder-form), never a resolved secret.
    public struct OnCompleteParams: Codable, Sendable, Equatable {
        public let method: String
        public let uri: String
        public let host: String
        /// Upstream HTTP status, or 0 when the request errored before/mid response.
        public let status: Int
        public let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case method, uri, host, status
            case durationMs = "duration_ms"
        }

        public init(method: String, uri: String, host: String, status: Int, durationMs: Int) {
            self.method = method
            self.uri = uri
            self.host = host
            self.status = status
            self.durationMs = durationMs
        }
    }
```

- [ ] **Step 4: Add `Method.onComplete`**

In `enum Method`:

```swift
    public enum Method {
        public static let initialize = "initialize"
        public static let onRequest = "on_request"
        public static let onComplete = "on_complete"
        public static let shutdown = "shutdown"
    }
```

- [ ] **Step 5: Add the params-carrying notification encoder**

After the existing `encodeNotification(method:)`:

```swift
    /// Encodes a notification WITH params (no `id`, no response expected) as one
    /// NDJSON line. Used by `on_complete`.
    public static func encodeNotification<P: Encodable>(method: String, params: P) throws -> String {
        let object = JSONValue.object([
            "jsonrpc": .string(JSONRPCRequest.version),
            "method": .string(method),
            "params": try JSONValue.encoding(params),
        ])
        return try line(from: object)
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter PluginRPCTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRPC.swift Tests/IrisKitTests/PluginRPCTests.swift
git commit -m "feat(plugins): OnCompleteParams + on_complete notification encoder"
```

---

## Task 4: `PluginInvoking.onComplete` + `HookDispatcher.onComplete` + `updateCompleteChain`

**Files:**
- Modify: `Sources/IrisKit/Plugins/HookDispatcher.swift`
- Test: `Tests/IrisKitTests/Plugins/HookDispatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

In `HookDispatcherTests.swift`, extend the `private actor MockInvoker` to record `onComplete` calls (add inside the actor body, after `onRequest`):

```swift
    private var completeRecords: [PluginRPC.OnCompleteParams] = []
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
        completeRecords.append(params)
    }
    var completeCalls: [PluginRPC.OnCompleteParams] { completeRecords }
```

Add a chain-entry helper for onComplete (after the existing `entry(...)` helper):

```swift
    private func completeEntry(_ inv: any PluginInvoking, match: HookMatch = HookMatch()) -> PluginChainEntry {
        PluginChainEntry(
            pluginId: inv.id,
            invoker: inv,
            hook: PluginHook(event: .onComplete, match: match, mutates: false, onFailure: .skip, timeoutMs: 1000)
        )
    }
```

Add the tests:

```swift
func testOnCompleteDeliversParamsToMatchingPlugin() async {
    let inv = MockInvoker(id: "p") { _ in .init(action: .pass) }
    let d = HookDispatcher()
    d.updateCompleteChain([completeEntry(inv, match: HookMatch(hosts: ["api.anthropic.com"]))])
    await d.onComplete(
        method: "POST", uri: "/v1/messages", host: "api.anthropic.com",
        contentType: "application/json", status: 200, durationMs: 12
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
        method: "GET", uri: "/x", host: "h", contentType: nil, status: 200, durationMs: 1
    )
    let records = await inv.completeCalls
    XCTAssertTrue(records.isEmpty, "status condition [500] must not match a 200 completion")
}

func testOnCompleteEmptyChainIsNoop() async {
    let d = HookDispatcher()
    await d.onComplete(method: "GET", uri: "/x", host: "h", contentType: nil, status: 0, durationMs: 1)
    // No crash, no entries — the onRequest chain is untouched.
    XCTAssertEqual(d.chainCountForTesting, 0)
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
```

For `testOnCompleteSwallowsPluginErrors`, add to `MockInvoker`:

```swift
    private var completeError: Error?
    func setOnCompleteThrows(_ error: Error) { completeError = error }
```

…and change the recording `onComplete` to honor it:

```swift
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
        if let completeError { throw completeError }
        completeRecords.append(params)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookDispatcherTests`
Expected: FAIL — `PluginInvoking` has no `onComplete`, `HookDispatcher` has no `updateCompleteChain`/`onComplete` (compile errors).

- [ ] **Step 3: Add `onComplete` to the `PluginInvoking` protocol + default no-op**

In HookDispatcher.swift, extend the protocol and add a default so existing conformers (e.g. `StubInvoker`) need no change:

```swift
public protocol PluginInvoking: Sendable {
    var id: String { get }
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
    /// Fire-and-forget completion notification. Read-only; no return value. Default
    /// is a no-op so conformers that declare no onComplete hook need not implement it.
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws
}

extension PluginInvoking {
    public func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {}
}
```

- [ ] **Step 4: Add the second chain box, updater, and dispatch method**

In `HookDispatcher`, add the box beside `chainBox`:

```swift
    private let chainBox = NIOLockedValueBox<[PluginChainEntry]>([])
    private let completeChainBox = NIOLockedValueBox<[PluginChainEntry]>([])
```

Add the updater (after `updateChain`):

```swift
    /// Pushed by `PluginHostManager` after each reconcile (onComplete chain).
    public func updateCompleteChain(_ chain: [PluginChainEntry]) {
        completeChainBox.withLockedValue { $0 = chain }
    }
```

Add the dispatch method (after `onRequest`, before `// MARK: - Wire conversion`):

```swift
    /// Fires the onComplete chain for a finished request. Caller MUST invoke this
    /// off the response-critical path (a detached `Task`): it is fire-and-forget,
    /// read-only, and never returns anything. Gating runs before any IPC; a request
    /// with no applicable onComplete hook costs nothing. Per-plugin errors (dead
    /// process, EPIPE) are logged and swallowed — a misbehaving sink can never
    /// affect the response (already relayed) nor other plugins' delivery.
    public func onComplete(
        method: String,
        uri: String,
        host: String,
        contentType: String?,
        status: Int,
        durationMs: Int
    ) async {
        let chain = completeChainBox.withLockedValue { $0 }
        if chain.isEmpty { return }
        let (path, _) = PlaceholderScanner.splitURI(uri)
        let applicable = chain.filter {
            $0.hook.match.matches(
                host: host, method: method, path: path,
                requestContentType: contentType, status: status
            )
        }
        if applicable.isEmpty { return }
        let params = PluginRPC.OnCompleteParams(
            method: method, uri: uri, host: host, status: status, durationMs: durationMs
        )
        for entry in applicable {
            do {
                try await entry.invoker.onComplete(params)
            } catch {
                logger.debug(
                    "plugin onComplete failed",
                    metadata: ["id": "\(entry.pluginId)", "error": "\(error)"]
                )
            }
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HookDispatcherTests`
Expected: PASS (all existing + 4 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/Plugins/HookDispatcher.swift Tests/IrisKitTests/Plugins/HookDispatcherTests.swift
git commit -m "feat(plugins): HookDispatcher.onComplete + separate onComplete chain"
```

---

## Task 5: `PluginHost.onComplete` + example plugin handling + real-delivery integration test

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHost.swift`
- Modify: `examples/plugins/header-tagger/Sources/header-tagger/main.swift`
- Modify: `examples/plugins/header-tagger/plugin.json`
- Test: `Tests/IntegrationTests/HeaderTaggerExampleTests.swift`

- [ ] **Step 1: Write the failing integration test**

Append to `HeaderTaggerExampleTests.swift` (inside the class):

```swift
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
            method: "POST", uri: "/v1/messages", host: "api.anthropic.com",
            status: 200, durationMs: 7
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HeaderTaggerExampleTests.testHeaderTaggerRecordsOnCompleteToScratch`
Expected: FAIL — `host.onComplete(...)` does not exist (compile error); even once added, the example plugin does not yet write the log → assertion fails.

- [ ] **Step 3: Implement `PluginHost.onComplete`**

In `PluginHost.swift`, after `onRequest(...)` (around line 209):

```swift
    /// Sends one `on_complete` NOTIFICATION (fire-and-forget; no reply, no pending
    /// continuation). Throws `.notRunning` if the process is gone, or rethrows a
    /// write failure (EPIPE on a dead plugin — F_SETNOSIGPIPE makes it throw, not
    /// signal). The dispatcher swallows these; a sink failure never affects traffic.
    public func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
        guard started, let stdinHandle else { throw PluginHostError.notRunning }
        let line = try PluginRPC.encodeNotification(method: PluginRPC.Method.onComplete, params: params)
        try stdinHandle.write(contentsOf: Data(line.utf8))
    }
```

(The empty `extension PluginHost: PluginInvoking {}` at line 323 already declares conformance; this actor-isolated method satisfies the protocol's `onComplete`, overriding the default no-op via dynamic dispatch — exactly as `onRequest` does.)

- [ ] **Step 4: Implement `on_complete` handling in the example plugin**

In `examples/plugins/header-tagger/Sources/header-tagger/main.swift`, add a helper after `emitLine`:

```swift
/// Appends one line to `on_complete.log` in the plugin's scratch dir. The daemon
/// sets our cwd to the (sandbox-writable) scratch dir, so a relative path is fine.
func appendCompletionLog(_ line: String) {
    let url = URL(fileURLWithPath: "on_complete.log")  // cwd == scratch dir
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
```

Add an `on_complete` case to the `switch` (after `on_request`):

```swift
    case "on_complete":
        // Notification: no reply. Record HTTP-level metadata to scratch.
        if let params = object["params"] as? [String: Any] {
            let method = params["method"] as? String ?? "?"
            let status = params["status"] as? Int ?? -1
            let uri = params["uri"] as? String ?? "?"
            appendCompletionLog("\(method) \(status) \(uri)")
        }
```

Update the file's top doc comment to mention `on_complete` (after the `on_request` paragraph):

```swift
//   on_complete -> a NOTIFICATION (no id, no reply): we append "METHOD STATUS URI"
//                  to on_complete.log in our scratch dir. Read-only observability.
```

- [ ] **Step 5: Declare the hook + scratch capability in the manifest**

Replace `examples/plugins/header-tagger/plugin.json` hooks/capabilities so it reads:

```json
{
  "id": "org.iris.example.header-tagger",
  "name": "Header Tagger",
  "version": "1.0.0",
  "description": "Adds an X-Iris-Plugin header to matched requests and logs completions (example plugin).",
  "api_version": 1,
  "executable": ".build/release/header-tagger",
  "hooks": [
    { "event": "on_request",
      "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "path_regex": "^/v1/" },
      "mutates": true, "on_failure": "skip", "timeout_ms": 200 },
    { "event": "on_complete",
      "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "path_regex": "^/v1/" },
      "mutates": false, "on_failure": "skip", "timeout_ms": 200 }
  ],
  "capabilities": { "network": [], "filesystem": ["scratch"] }
}
```

- [ ] **Step 6: Rebuild the example binary, then run the test**

The integration test runs the real example binary located by `ExecutableLocator.headerTagger`. Rebuild it first:

Run: `swift build` (builds the `header-tagger` target via the main Package.swift)
Then: `swift test --filter HeaderTaggerExampleTests`
Expected: PASS — both the existing onRequest tests and the new onComplete delivery test.

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHost.swift \
        examples/plugins/header-tagger/Sources/header-tagger/main.swift \
        examples/plugins/header-tagger/plugin.json \
        Tests/IntegrationTests/HeaderTaggerExampleTests.swift
git commit -m "feat(plugins): PluginHost.onComplete + example plugin on_complete logging"
```

---

## Task 6: `PluginHostManager` onComplete chain + `Daemon` wiring

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHostManager.swift`
- Modify: `Sources/irisd/Daemon.swift` (around line 190)
- Test: `Tests/IntegrationTests/PluginHostManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Inspect `PluginHostManagerTests.swift` for the existing harness (`makeManager(...)` around line 66 already accepts `onChainChanged`). Add a test that a plugin declaring an `on_complete` hook lands in the onComplete chain. Mirror the existing onRequest-chain test (the one capturing `pushed.withLockedValue` around line 135), but capture a second box and assert on the complete chain. Add:

```swift
func testReconcilePublishesOnCompleteChain() async throws {
    let completePushed = NIOLockedValueBox<[PluginChainEntry]>([])
    // Install a plugin whose manifest declares BOTH an on_request and an on_complete
    // hook (reuse this file's existing install helper for the fixture plugin, adding
    // an on_complete hook to its manifest — see the onRequest equivalent above).
    let manager = makeManager(
        onChainChanged: { _ in },
        onCompleteChainChanged: { chain in completePushed.withLockedValue { $0 = chain } }
    )
    await manager.startEnabled()
    // The fixture must be enabled+hash-matching so it starts and republishes.
    let chain = completePushed.withLockedValue { $0 }
    XCTAssertTrue(
        chain.contains { $0.hook.event == .onComplete },
        "an installed on_complete hook must be published to the onComplete chain"
    )
    await manager.shutdown()
}
```

> Note for the implementer: this file already has an install/enable helper and a fixture manifest used by `testReconcilePublishes...` (onRequest). Add an `on_complete` hook entry to that fixture manifest, and add the `onCompleteChainChanged` parameter to the local `makeManager(...)` helper (defaulting to `{ _ in }`). Keep the assertion focused on `event == .onComplete`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginHostManagerTests.testReconcilePublishesOnCompleteChain`
Expected: FAIL — `PluginHostManager.init` has no `onCompleteChainChanged` parameter (compile error).

- [ ] **Step 3: Add the `onCompleteChainChanged` stored callback + init param**

In `PluginHostManager.swift`, add the property beside `onChainChanged` (line 33):

```swift
    private let onChainChanged: @Sendable ([PluginChainEntry]) -> Void
    private let onCompleteChainChanged: @Sendable ([PluginChainEntry]) -> Void
```

Add the init parameter (after `onChainChanged`, line 50) with a default:

```swift
        onChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
        onCompleteChainChanged: @escaping @Sendable ([PluginChainEntry]) -> Void = { _ in },
```

Assign it in the init body (after `self.onChainChanged = onChainChanged`):

```swift
        self.onChainChanged = onChainChanged
        self.onCompleteChainChanged = onCompleteChainChanged
```

- [ ] **Step 4: Publish both chains**

In `republishChain(desired:)` (lines 238–247), build and push the onComplete chain too:

```swift
    private func republishChain(desired: [Plugin]) {
        var requestEntries: [PluginChainEntry] = []
        var completeEntries: [PluginChainEntry] = []
        for plugin in desired.sorted(by: { $0.order < $1.order }) {
            guard let host = hosts[plugin.manifest.id] else { continue }
            for hook in plugin.manifest.hooks {
                let entry = PluginChainEntry(pluginId: plugin.manifest.id, invoker: host, hook: hook)
                switch hook.event {
                case .onRequest: requestEntries.append(entry)
                case .onComplete: completeEntries.append(entry)
                }
            }
        }
        onChainChanged(requestEntries)
        onCompleteChainChanged(completeEntries)
    }
```

Find the other `onChainChanged([])` call (the shutdown/clear path, line 120) and clear the complete chain there too:

```swift
        onChainChanged([])
        onCompleteChainChanged([])
```

- [ ] **Step 5: Wire it in the Daemon**

In `Sources/irisd/Daemon.swift`, line 190, add the second callback after `onChainChanged`:

```swift
            onChainChanged: { [hookDispatcher] chain in hookDispatcher.updateChain(chain) },
            onCompleteChainChanged: { [hookDispatcher] chain in hookDispatcher.updateCompleteChain(chain) },
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter PluginHostManagerTests`
Expected: PASS (existing onRequest-chain tests + the new onComplete-chain test).

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHostManager.swift Sources/irisd/Daemon.swift \
        Tests/IntegrationTests/PluginHostManagerTests.swift
git commit -m "feat(plugins): publish + wire the onComplete chain (manager → daemon)"
```

---

## Task 7: `MITMHandler` insertion + proxy E2E (recording invoker)

**Files:**
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift` (`forwardRequest`, lines 94–219)
- Test: `Tests/IntegrationTests/PluginOnCompleteE2ETests.swift` (new)

- [ ] **Step 1: Write the failing E2E test**

Create `Tests/IntegrationTests/PluginOnCompleteE2ETests.swift`. It builds a real `ProxyServer` + `MockUpstream` (no plugin process needed — a `RecordingInvoker` is pushed onto the complete chain), sends one request through the proxy, and asserts the recorder saw the completion with the upstream status. **Reuse the harness construction from `PluginDispatchE2ETests.swift`** (the CA/MockUpstream/ProxyServer setup, lines 60–145) — copy it into this file, dropping the `PluginHost` (no onRequest plugin), and push the recorder via `proxy.hookDispatcher.updateCompleteChain([...])` instead of `updateChain`. The request-sending client mirrors the one in `PluginDispatchE2ETests` (a `URLSession` or NIO client through the proxy port trusting `proxyCANIO`).

```swift
import Foundation
import IrisKit
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1
import XCTest

/// A minimal PluginInvoking that records onComplete deliveries (no process).
private struct RecordingInvoker: PluginInvoking {
    let id: String
    let box: NIOLockedValueBox<[PluginRPC.OnCompleteParams]>
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult { .init(action: .pass) }
    func onComplete(_ params: PluginRPC.OnCompleteParams) async throws {
        box.withLockedValue { $0.append(params) }
    }
}

final class PluginOnCompleteE2ETests: XCTestCase {
    func testRequestThroughProxyFiresOnCompleteWithUpstreamStatus() async throws {
        // --- Build harness: copy the MockUpstream + CA + ProxyServer setup from
        //     PluginDispatchE2ETests.makeHarness (lines 64–132), WITHOUT a PluginHost.
        //     Keep references: `proxy`, `proxyPort`, `proxyCANIO`, `mock`.
        // (Engineer: paste that block here; it is established harness infrastructure.)

        let records = NIOLockedValueBox<[PluginRPC.OnCompleteParams]>([])
        proxy.hookDispatcher.updateCompleteChain([
            PluginChainEntry(
                pluginId: "rec",
                invoker: RecordingInvoker(id: "rec", box: records),
                hook: PluginHook(event: .onComplete, match: HookMatch(hosts: ["localhost"]),
                                 mutates: false, onFailure: .skip, timeoutMs: 1000)
            )
        ])

        // Send one request through the proxy to the mock upstream (mirror the client
        // in PluginDispatchE2ETests). The mock answers e.g. 200.
        // ... perform the request ...

        // onComplete is dispatched from a detached Task; poll briefly.
        var seen: [PluginRPC.OnCompleteParams] = []
        for _ in 0..<100 {
            seen = records.withLockedValue { $0 }
            if !seen.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(seen.count, 1, "exactly one onComplete per request")
        XCTAssertEqual(seen.first?.host, "localhost")
        XCTAssertEqual(seen.first?.status, 200, "status captured from the upstream response")
        // Security (§6.1): the params carry the ORIGINAL request URI (captured at
        // MITMHandler.swift:119, BEFORE substitution), never a resolved secret. The
        // sent path round-trips verbatim — no substituted value reaches the plugin.
        XCTAssertEqual(seen.first?.uri, "/v1/messages", "onComplete sees the original (pre-substitution) URI")

        // teardown: proxy.stop(), mock.stop()
    }
}
```

> Note for the implementer: the harness paste is mechanical (the CA/MockUpstream/request-client code already exists verbatim in `PluginDispatchE2ETests.swift`). The NEW assertions are the recorder + status check above. If preferred, extract a shared harness helper rather than copy — but do not block this task on a refactor.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginOnCompleteE2ETests`
Expected: FAIL — `forwardRequest` never calls `dispatcher.onComplete`, so the recorder stays empty → `seen.count == 0`. (Mutation check: this is exactly why the test is meaningful — it is red until the insertion exists.)

- [ ] **Step 3: Capture `originalContentType` in `forwardRequest`**

In `MITMHandler.swift`, after `let originalMethod = head.method.rawValue` (line 120):

```swift
        let originalMethod = head.method.rawValue
        // Request content-type, captured here so onComplete gating still has it at
        // completion (the head is gone by then). Like originalURI, this is request
        // metadata — placeholder-form, never a resolved secret.
        let originalContentType = head.headers.first(name: "content-type")
```

- [ ] **Step 4: Dispatch `onComplete` in both `.whenComplete` branches**

In the `.success` branch, after `Task { await ring.append(event) }` (line 192):

```swift
                let ring = server.eventRing
                Task { await ring.append(event) }
                // Fire-and-forget observability: never on the response-critical path.
                Task {
                    await server.hookDispatcher.onComplete(
                        method: originalMethod, uri: originalURI, host: host,
                        contentType: originalContentType,
                        status: outcome.statusCode, durationMs: Int(duration)
                    )
                }
```

In the `.failure` branch, after its `Task { await ring.append(event) }` (line 203):

```swift
                let ring = server.eventRing
                Task { await ring.append(event) }
                // status=0 sentinel: errored before/mid response (design C5).
                Task {
                    await server.hookDispatcher.onComplete(
                        method: originalMethod, uri: originalURI, host: host,
                        contentType: originalContentType,
                        status: 0, durationMs: Int(duration)
                    )
                }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PluginOnCompleteE2ETests`
Expected: PASS — the recorder sees exactly one onComplete with `status: 200`.

- [ ] **Step 6: Run the full proxy + plugin suites for regression**

Run: `swift test --filter ProxyEndToEndTests && swift test --filter PluginDispatchE2ETests`
Expected: PASS — the response streaming path is unchanged when no onComplete hook applies (empty complete chain → `onComplete` returns immediately).

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/Proxy/MITMHandler.swift Tests/IntegrationTests/PluginOnCompleteE2ETests.swift
git commit -m "feat(plugins): dispatch onComplete at request completion (MITMHandler)"
```

---

## Task 8: Final verification, docs note, PR

**Files:**
- Modify: `docs/plugins-design.md` (mark `onComplete` shipped in §13)

- [ ] **Step 1: Build release with zero warnings**

Run: `swift build -c release`
Expected: builds clean, **0 warning** (strict-concurrency complete is on for SPM targets).

- [ ] **Step 2: Run the full test suite**

Run: `swift test`
Expected: ALL green (the pre-change baseline was 664/0; this adds ~12 unit + 2 integration tests, all passing).

- [ ] **Step 3: Lint**

Run: `swift-format lint --strict --recursive Sources Tests`
Expected: no output, exit 0. (Reminder from memory: do NOT pipe through `tail` — the pipe captures `tail`'s exit code, masking lint failures. Run lint without a pipe.)

- [ ] **Step 4: Note `onComplete` as shipped in the design**

In `docs/plugins-design.md` §13 "Phases ultérieures", update the first bullet line referencing observability/`onComplete` to mark it shipped (e.g. append "— `onComplete` ✅ livré (voir `plugins-oncomplete-design.md`)"). Keep `onResponse` listed as still pending (PR 2).

```bash
git add docs/plugins-design.md
git commit -m "docs(plugins): mark onComplete shipped in the design roadmap"
```

- [ ] **Step 5: Push the branch and open the PR**

```bash
git push -u origin feat/plugins-oncomplete
gh pr create --title "feat(plugins): onComplete hook (observability tier)" --body "$(cat <<'EOF'
## Résumé

Ajoute le hook `onComplete` : observabilité fire-and-forget, lecture seule, déclenchée à la fin de chaque requête proxifiée. Métadonnées HTTP-level only (method/uri/host/status/durationMs). Aucun conflit SPECS §7.2 (la réponse n'est jamais lue/bufferisée/modifiée). Première des deux PR de l'extension réponse/complétion ; `onResponse` suit séparément.

Design : `docs/plugins-oncomplete-design.md`. Plan : `docs/plugins-oncomplete-plan.md`.

## Smoke testing

- [ ] `swift build -c release` 0 warning ; `swift test` vert ; `swift-format lint --strict` clean.
- [ ] Daemon éphémère isolé : un plugin déclarant `on_complete` reçoit la notification après une vraie requête (preuve : marqueur dans son scratch), avec le bon `status`.
- [ ] Une requête sans hook `onComplete` applicable conserve le streaming temps-réel (réponse byte-for-byte inchangée, pas de bufferisation).
- [ ] Un plugin `onComplete` lent/mort ne casse NI ne retarde la réponse client.
- [ ] Aucun secret ni body/header de réponse dans les params `on_complete` (uri = placeholder-form).

https://claude.ai/code/session_01AJRMr7Bd6wq9MePy1tceLN
EOF
)"
```

> Then follow `CLAUDE.md §8` for the Gemini review polling loop and merge gate (explicit user confirmation before `gh pr merge --squash`).

---

## Self-Review notes (author)

- **Spec coverage:** §1 periphery (status/event/RPC/host/dispatcher/manager/MITM/example/tests) → Tasks 1–7; tests (unit/integration/security) → embedded per task + Task 8. ✅
- **Type consistency:** `OnCompleteParams(method,uri,host,status,durationMs)`, `updateCompleteChain`, `onCompleteChainChanged`, `HookMatch.status: [Int]?`, `matches(...,status:Int?=nil)`, `HookEvent.onComplete` — names used identically across all tasks. ✅
- **Security:** params carry no body/header; `uri` is `originalURI` (placeholder-form, pre-substitution); dispatch is off-critical-path (detached Task) + EPIPE-safe (F_SETNOSIGPIPE). ✅
- **Known residual (not in scope):** the sandbox grants scratch writes unconditionally (`PluginSandboxProfile.swift:31`), so `filesystem:["scratch"]` is documentary for the example; pre-existing P2a/P2b behavior, not introduced here.
