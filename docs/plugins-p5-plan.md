# Plugins P5 — Example Plugin + Integration Test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `header-tagger` example (today an inert P1 stub) into a real, shippable IRIS plugin that speaks the NDJSON/JSON-RPC protocol and adds an `X-Iris-Plugin: header-tagger` header to matched requests, and prove the *shipped binary* works with a focused integration test.

**Architecture:** `examples/plugins/header-tagger/` stays a standalone SwiftPM package (a user clones just that folder and `swift build`s it). To let the integration test run the *real* binary, the main package gains a `header-tagger` executable **target with a shared `path:`** (pointing at the example's `Sources/`) — one source of truth, built into the main package's products dir so `ExecutableLocator` can find it (same trick as the `iris-test-plugin` fixture). The test starts a real `PluginHost` (real `PluginSandbox`) against that binary; **no proxy/TLS** — the full request path is already proven by `PluginDispatchE2ETests` with the fixture.

**Tech Stack:** Swift 5.9+, SwiftPM, Foundation-only plugin binary, XCTest, NIOHTTP1 (`HTTPRequestHead`).

---

## Key facts (verified against live source 2026-06-22 — do not re-derive)

- **NDJSON protocol** (from `Sources/iris-test-plugin/main.swift`, the reference server): one compact JSON object per line on stdin/stdout. Methods the daemon sends: `initialize`, `on_request` (snake_case!), `shutdown`. Each request carries an `id` the plugin must **echo back verbatim**. Replies are `{"jsonrpc":"2.0","id":<id>,"result":{...}}`.
  - `initialize` reply: `result` = `{"ready": true}`.
  - `on_request` reply: `result` = `{"action":"modify","headers":[["X-Iris-Plugin","header-tagger"]]}`.
  - `shutdown`: exit(0). Unknown/garbage lines: ignore.
- **Overlay merge is daemon-side** (`HookDispatcher.applyModify`, `HookDispatcher.swift:211`): the plugin returns ONLY the headers it wants to set; Iris overlays them by name via `replaceOrAdd`, so unspecified headers (the `{{kc:...}}` credential placeholder) survive. The plugin never echoes them back. Header removal is not supported in v1.
- **Security invariant §3:** `on_request` sees credential PLACEHOLDERS only; Iris substitutes the real value AFTER plugins run. `header-tagger` therefore declares empty capabilities and never reads a secret.
- **`PluginHost`** (`Sources/IrisKit/Plugins/PluginHost.swift`):
  - `init(spec: PluginLaunchSpec, sandbox: PluginSandbox, timeouts: Timeouts = …, logger: Logger, onUnexpectedExit: @escaping @Sendable (String) async -> Void)`
  - `PluginLaunchSpec(id:executablePath:capabilities:configValues:scratchDir:)` — `scratchDir` is a `URL`, must be the **realpath** (Seatbelt canonicalises write paths, handoff #3).
  - `Timeouts(initialize:shutdown:)`, `func start() async throws` (runs `initialize`), `func shutdown() async`, and it conforms to `PluginInvoking`: `func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws -> PluginRPC.OnRequestResult`.
- **`PluginRPC`** (`Sources/IrisKit/Plugins/PluginRPC.swift`):
  - `OnRequestParams(method:String, uri:String, host:String, headers:[[String]], body:Body?)`
  - `OnRequestResult.action: Action` where `Action ∈ {pass, modify, block, respond}`; `headers: [[String]]?`.
- **`HookDispatcher`** (`Sources/IrisKit/Plugins/HookDispatcher.swift`): `HookDispatcher()` (default logger); `func updateChain([PluginChainEntry])`; `func onRequest(head: HTTPRequestHead, body: ByteBuffer?, host: String) async -> HookOutcome`. `HookOutcome ∈ {proceed(head:body:), block(...), respond(...)}`.
  - `PluginChainEntry(pluginId:String, invoker: any PluginInvoking, hook: PluginHook)`.
- **`PluginHook`** init: `PluginHook(event: .onRequest, match: HookMatch, mutates: Bool = false, onFailure: .skip|.block = .skip, timeoutMs: Int = 1000)`.
- **`HookMatch`** init: `HookMatch(hosts: [String] = [], methods: [String] = [], pathRegex: String? = nil, contentType: String? = nil)`. Host match is **exact** (no glob — parity with `ExfilRuleEngine`).
- **`PluginCapabilities()`** = empty network + filesystem. **`PluginSandbox(shimPath:)`**.
- **`ExecutableLocator`** (`Tests/IntegrationTests/CLISupport/ExecutableLocator.swift`): resolves products next to the running `.xctest` bundle. Has `iris`, `irisd`, `sandboxExec`, `testPlugin`. Add `headerTagger`.
- **`realpath()`** is a module-internal `extension URL` defined in `Tests/IntegrationTests/PluginHostTests.swift` — **reuse it, do NOT redefine** (redeclaration error). The per-class `scratchDir()` helper is `private` and is duplicated per test class (copy the pattern).
- **`iris-test-plugin` target** has `swiftSettings: strictConcurrency` and **no `product` entry** (test-only). The `header-tagger` main-package target mirrors this (no product entry — it ships via its own package, not the main one).
- **Linting:** CI lint is `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` — it does **not** scan `examples/`, so `header-tagger/main.swift` is not CI-linted, but the new test file under `Tests/` **is** (`--strict` → camelCase, 1 arg/line, ≤120 cols).
- **TOFU re-pin path (memory I1, verified):** `install` rejects an already-installed id (`duplicateId` -32031) — there is NO in-place re-pin. The only way to re-pin after a rebuild is **remove then install**. The current README's "re-run install/enable to re-pin" wording is WRONG; fix it.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `Package.swift` | Modify | Add `header-tagger` executable target (shared `path:`); add it to `IntegrationTests` deps. |
| `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift` | Modify | Add `headerTagger` locator. |
| `Tests/IntegrationTests/HeaderTaggerExampleTests.swift` | Create | Two tests: protocol-level `modify`+tag, and dispatcher-level overlay preserves placeholder. |
| `examples/plugins/header-tagger/Sources/header-tagger/main.swift` | Modify | Replace inert stub with the NDJSON server. |
| `examples/plugins/header-tagger/README.md` | Modify | "implemented" status, what it does, protocol pointer, correct TOFU re-pin steps. |
| `examples/plugins/header-tagger/plugin.json` | Modify | Drop "Runtime wiring lands in P3" from `description`. |

**Out of scope (YAGNI):** `onResponse`/`onComplete`, schema-driven config, duplicating the proxy E2E harness, general protocol docs in `manuel.html` (separate doc chantier), `.pkg` embedding (Phase 9).

---

## Task 1: Build wiring — main-package target + locator

**Files:**
- Modify: `Package.swift` (after the `iris-test-plugin` target, lines 70–73; and `IntegrationTests` deps, line 90)
- Modify: `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift:20`

- [ ] **Step 1: Add the `header-tagger` target to `Package.swift`**

Insert immediately after the `iris-test-plugin` `.executableTarget` (after its closing `),`):

```swift
        .executableTarget(
            name: "header-tagger",
            path: "examples/plugins/header-tagger/Sources/header-tagger",
            swiftSettings: strictConcurrency
        ),
```

- [ ] **Step 2: Add `header-tagger` to the IntegrationTests dependencies**

In the `.testTarget(name: "IntegrationTests", dependencies: [ … ])` list, add the line after `"iris-test-plugin",`:

```swift
                "header-tagger",
```

- [ ] **Step 3: Add the locator**

In `ExecutableLocator.swift`, after `static var testPlugin: URL { url(forProduct: "iris-test-plugin") }`:

```swift
    static var headerTagger: URL { url(forProduct: "header-tagger") }
```

- [ ] **Step 4: Verify the package resolves and the (still-stub) binary builds**

Run: `swift build --product header-tagger`
Expected: builds successfully (the inert stub compiles). Confirms the shared-`path:` target and the example package's nested `Package.swift` do not conflict.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/IntegrationTests/CLISupport/ExecutableLocator.swift
git commit -m "build(plugins): build header-tagger example into main package for integration tests"
```

---

## Task 2: Failing integration test (RED)

**Files:**
- Create: `Tests/IntegrationTests/HeaderTaggerExampleTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IntegrationTests/HeaderTaggerExampleTests.swift`:

```swift
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
        try? FileManager.default.removeItem(at: scratch)
        if let caught = caught { throw caught }

        XCTAssertEqual(result?.action, .modify, "header-tagger must return a modify action")
        let tagged = (result?.headers ?? []).contains {
            $0.count == 2 && $0[0].caseInsensitiveCompare("X-Iris-Plugin") == .orderedSame
                && $0[1] == "header-tagger"
        }
        XCTAssertTrue(tagged, "modify result must add X-Iris-Plugin: header-tagger")
    }

    /// Integration with the real HookDispatcher: the overlay merge adds the tag and
    /// PRESERVES the credential placeholder (so Iris can substitute it afterwards).
    func testHeaderTaggerOverlayPreservesCredentialPlaceholder() async throws {
        let scratch = try scratchDir()
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
        try? FileManager.default.removeItem(at: scratch)

        guard case .proceed(let outHead, _) = outcome else {
            XCTFail("expected .proceed, got \(outcome)")
            return
        }
        XCTAssertEqual(
            outHead.headers.first(name: "x-iris-plugin"), "header-tagger",
            "the tag header must reach the forwarded request"
        )
        XCTAssertEqual(
            outHead.headers.first(name: "x-api-key"), "{{kc:anthropic_api_key}}",
            "the credential placeholder must survive the overlay so Iris can substitute it"
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `swift test --filter HeaderTaggerExampleTests`
Expected: FAIL. The current `main.swift` stub writes to stderr and exits without answering `initialize`, so `host.start()` throws (`PluginHostError.timeout`/`.malformedResponse`/`.initializeRejected`). Both tests fail at `try await host.start()`. (Compilation must succeed — that proves the types/locator from Task 1 are correct.)

- [ ] **Step 3: Commit the failing test**

```bash
git add Tests/IntegrationTests/HeaderTaggerExampleTests.swift
git commit -m "test(plugins): add failing integration test for header-tagger example"
```

---

## Task 3: Implement the NDJSON server (GREEN)

**Files:**
- Modify: `examples/plugins/header-tagger/Sources/header-tagger/main.swift`

- [ ] **Step 1: Replace the stub with the real server**

Overwrite `examples/plugins/header-tagger/Sources/header-tagger/main.swift` with:

```swift
import Foundation

// header-tagger — IRIS example plugin.
//
// A minimal, safe `onRequest` mutator: it adds an `X-Iris-Plugin: header-tagger`
// header to every matched request. Iris decides WHICH requests are matched (the
// `hooks[].match` block in plugin.json); this process only answers the protocol.
//
// IPC protocol (NDJSON / JSON-RPC 2.0 over stdio — see docs/plugins-design.md §8):
// Iris (the daemon) is the CLIENT: it writes one compact JSON object per line to
// our stdin and we reply with one compact JSON object per line on stdout. Three
// methods arrive over a plugin's lifetime:
//
//   initialize  -> reply {"result":{"ready":true}} once, at startup.
//   on_request  -> reply an `action` per matched request. We always return
//                  `modify` with our tag header. Iris OVERLAYS the returned
//                  headers by name onto the real request, so unspecified headers
//                  (notably the `{{kc:...}}` credential placeholder Iris must
//                  still substitute) are preserved — we never echo them back.
//   shutdown    -> exit gracefully.
//
// The request we see at `on_request` carries credential PLACEHOLDERS
// (`{{kc:NAME}}`), never resolved secret values: Iris substitutes the real value
// AFTER plugins run (security invariant, design §3). A plugin can never read a
// secret. Accordingly this plugin declares no capabilities.
//
// Foundation-only on purpose: the binary stays self-contained so it runs under
// Iris's deny-by-default sandbox with empty capabilities.

/// Writes one compact JSON object followed by a newline to stdout (NDJSON framing).
func emitLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data)
    try? FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
}

// One JSON request per line on stdin; reply (or stay silent) per method.
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }  // ignore anything that is not a JSON object
    let id = object["id"] ?? NSNull()  // echo the request id back verbatim

    switch object["method"] as? String {
    case "initialize":
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["ready": true]])
    case "on_request":
        // Always tag. Header removal is not supported; this is a pure overlay.
        emitLine([
            "jsonrpc": "2.0", "id": id,
            "result": ["action": "modify", "headers": [["X-Iris-Plugin", "header-tagger"]]],
        ])
    case "shutdown":
        exit(0)
    default:
        break  // unknown method: ignore (forward-compatible)
    }
}
exit(0)
```

- [ ] **Step 2: Run the integration tests to verify they PASS**

Run: `swift test --filter HeaderTaggerExampleTests`
Expected: PASS (2 tests). `host.start()` now completes the `initialize` handshake; `on_request` returns `modify` with the tag; the dispatcher overlay adds the tag and keeps `x-api-key: {{kc:anthropic_api_key}}`.

- [ ] **Step 3: Verify the standalone example package still builds**

Run: `swift build --package-path examples/plugins/header-tagger -c release`
Expected: builds `.build/release/header-tagger` (proves the shippable package is intact — a user can clone just that folder).

- [ ] **Step 4: Commit**

```bash
git add examples/plugins/header-tagger/Sources/header-tagger/main.swift
git commit -m "feat(plugins): implement header-tagger example NDJSON onRequest server"
```

---

## Task 4: Docs — README + manifest description

**Files:**
- Modify: `examples/plugins/header-tagger/README.md`
- Modify: `examples/plugins/header-tagger/plugin.json:5`

- [ ] **Step 1: Rewrite the README**

Overwrite `examples/plugins/header-tagger/README.md` with:

```markdown
# header-tagger — IRIS example plugin

A minimal, complete IRIS plugin. It adds an `X-Iris-Plugin: header-tagger` header
to every request IRIS routes to it. Use it as a starting point for your own plugin.

## What it does

The plugin is an `onRequest` mutator. IRIS decides which requests it sees via the
`hooks[].match` block in `plugin.json` (here: `POST` requests to `api.anthropic.com`
under `/v1/`). For each matched request the plugin returns a `modify` action that
overlays the tag header; every other header — including the `{{kc:...}}` credential
placeholder IRIS substitutes afterwards — is preserved.

It requests **no capabilities** (no network, no filesystem) and never sees a
resolved secret: IRIS substitutes credentials only *after* plugins run (security
invariant). The full IPC protocol (NDJSON / JSON-RPC 2.0 over stdio) is documented
in `docs/plugins-design.md §8`; the `Sources/header-tagger/main.swift` here is the
smallest faithful implementation of it — read it as living documentation.

## Build

```bash
swift build -c release
```

This produces `.build/release/header-tagger`, the path referenced by `plugin.json`'s
`executable`.

## Install (requires a running irisd)

```bash
iris plugin install examples/plugins/header-tagger
iris plugin enable org.iris.example.header-tagger
```

The content hash is pinned at install time (TOFU). If you rebuild the binary after
installing, the directory content changes and IRIS marks the plugin
`needs-reapproval`. Re-pinning is **remove then reinstall** (install rejects an
already-installed id — there is no in-place re-pin):

```bash
iris plugin rm org.iris.example.header-tagger
iris plugin install examples/plugins/header-tagger
iris plugin enable org.iris.example.header-tagger
```
```

- [ ] **Step 2: Fix the manifest description**

In `examples/plugins/header-tagger/plugin.json`, change the `description` value (line 5) from:

```json
  "description": "Adds an X-Iris-Plugin header to matched requests (demo). Runtime wiring lands in P3.",
```

to:

```json
  "description": "Adds an X-Iris-Plugin header to matched requests (example plugin).",
```

- [ ] **Step 3: Verify nothing broke**

Run: `swift build --package-path examples/plugins/header-tagger -c release`
Expected: still builds (README/manifest are non-code; this just confirms the JSON edit is valid).

- [ ] **Step 4: Commit**

```bash
git add examples/plugins/header-tagger/README.md examples/plugins/header-tagger/plugin.json
git commit -m "docs(plugins): document header-tagger example, fix TOFU re-pin steps"
```

---

## Final verification (before PR)

- [ ] `swift build`
- [ ] `swift test` — full suite green, no regressions (expect 662 + 2 = **664 tests**, 0 failures).
- [ ] `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` — exit 0 (the new test file must pass `--strict`).
- [ ] `swift build --package-path examples/plugins/header-tagger -c release` — standalone shippable package builds.
- [ ] Open PR from `feat/plugins-p5-example` with a smoke checklist covering: (1) `swift test --filter HeaderTaggerExampleTests` passes; (2) standalone example builds; (3) `main.swift` is Foundation-only (`otool -L .build/release/header-tagger` shows only `/usr/lib` + `/System`); (4) README TOFU steps say remove-then-reinstall.

---

## Self-Review

- **Spec coverage (design §11 + §12):** §11 "Swift example, `onRequest` mutator adds `X-Iris-Plugin: header-tagger`, empty capabilities, living documentation" → Tasks 3 + 4. §12 "integration: example plugin proves `onRequest` modifies the forwarded request" → Task 2/3 (dispatcher test proves the tag reaches the request and the placeholder is preserved). "substitution applies after" / "failing plugin doesn't bypass scan" → already proven by `PluginDispatchE2ETests` (fixture), explicitly out of P5 scope (no harness duplication). "plugin never receives a resolved secret" → structural (empty caps + invariant §3, proven in P3); the placeholder-preservation test reinforces it.
- **Placeholder scan:** none — every step has exact code/commands.
- **Type consistency:** `headerTagger` locator, `PluginLaunchSpec`, `PluginHost`/`PluginInvoking.onRequest`, `PluginRPC.OnRequestParams`/`OnRequestResult.action`/`headers`, `HookDispatcher.onRequest`→`HookOutcome.proceed`, `PluginChainEntry`, `PluginHook`/`HookMatch` inits — all match live source read this session. `on_request` (snake) and the echoed `id` match the fixture's wire contract.
- **Scope:** single focused plan, no decomposition needed.
