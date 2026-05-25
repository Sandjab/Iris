# Phase 4 — Scoping `allowed_hosts` + Exfiltration Detection: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pass IRIS's MITM proxy from naïve placeholder substitution to host-scoped substitution with active exfiltration detection (rules R1–R5) and policy enforcement (`block_only` / `block_and_notify` / `block_notify_pause`), per SPECS §8–§9.

**Architecture:** Two-pass pipeline introduced in `MITMHandler`. A new pure static `PlaceholderScanner` extracts hits (name + location + snippet) without touching the store. A new actor `ExfilRuleEngine` applies R1–R5 against `RequestContext` (host, method, path, content-type) and returns `ExfilDecision { .allow(resolvable) | .block(alert) }`. `PlaceholderEngine` gains a `substituteResolvable(...)` method that mutates the request only for hits the evaluator authorized. `MITMHandler` orchestrates and emits one `Event` per outcome (`.substituted`, `.noMatch`, `.exfilBlocked`, `.passThrough` for bypass).

**Tech Stack:** Swift 5.9+, swift-nio + NIOHTTP1 (existing), swift-log (existing), XCTest (existing). No new external dependencies.

**Source design:** [`docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md`](../specs/2026-05-25-phase-4-scoping-exfil-design.md)

**Spec → API correction:** The design referenced `SecretStore.metadata(forName:)`. The existing protocol already exposes `secret(named:)` returning `Secret` metadata. This plan uses the existing API — no protocol extension needed.

---

## File map

**New files:**

- `Sources/IrisKit/Placeholder/PlaceholderScanner.swift` — pure static scanner + `PlaceholderHit` type.
- `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift` — actor implementing R1–R5, `ExfilDecision`, `RequestContext`, internal `SlidingMinuteCounter`.
- `Tests/IrisKitTests/PlaceholderScannerTests.swift` — scanner unit tests.
- `Tests/IrisKitTests/ExfilRuleEngineTests.swift` — evaluator unit tests.

**Modified files:**

- `Sources/IrisKit/Placeholder/PlaceholderEngine.swift` — add `substituteResolvable(...)` method using existing LRU value cache.
- `Sources/IrisKit/Proxy/ProxyServer.swift` — add `exfilRuleEngine` and `onExfilAttempt` to `Configuration`, instantiate in init or accept injected.
- `Sources/IrisKit/Proxy/MITMHandler.swift` — refactor `applySubstitution` → `processRequest` with `ProcessedRequest.Outcome` enum, apply policy on `.blocked`.
- `Sources/irisd/Daemon.swift` — wire `ExfilRuleEngine` (read `maxSubstitutionsPerMinute` + `onExfilAttempt` from config) into `ProxyServer.Configuration`.
- `Tests/IntegrationTests/ProxyEndToEndTests.swift` — add 4 integration cases (host mismatch, scoped OK, auto-pause, R5 volume).
- `Tests/IrisKitTests/RedactionTests.swift` — add 1 invariance test on alert snippet.

---

## Task 1: `PlaceholderHit` + `PlaceholderScanner` (pure, no store)

**Files:**
- Create: `Sources/IrisKit/Placeholder/PlaceholderScanner.swift`
- Test: `Tests/IrisKitTests/PlaceholderScannerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/IrisKitTests/PlaceholderScannerTests.swift`:

```swift
import XCTest

@testable import IrisKit

final class PlaceholderScannerTests: XCTestCase {
    func testHitInCanonicalHeaderValue() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/v1/messages",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "foo")
        XCTAssertEqual(hits[0].location, .header(name: "authorization"))
    }

    func testHitInHeaderName() {
        let hits = PlaceholderScanner.scan(
            headers: [("X-{{kc:foo}}", "bar")],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "foo")
        if case .header(let n) = hits[0].location {
            XCTAssertTrue(n.contains("{{kc:foo}}"))
        } else {
            XCTFail("expected header location")
        }
    }

    func testHitInURLPath() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo/{{kc:bar}}/baz",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .urlPath)
    }

    func testHitInQueryString() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo?key={{kc:bar}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .queryString)
    }

    func testHitInBody() {
        let body = Data(#"{"key":"{{kc:bar}}"}"#.utf8)
        let hits = PlaceholderScanner.scan(headers: [], uri: "/", body: body)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .body)
    }

    func testMultipleHitsSameSecretMultipleLocations() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/foo?x={{kc:foo}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.name)), ["foo"])
    }

    func testMultipleDistinctSecrets() {
        let hits = PlaceholderScanner.scan(
            headers: [
                ("Authorization", "Bearer {{kc:foo}}"),
                ("X-Other", "{{kc:bar}}"),
            ],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(Set(hits.map(\.name)), ["foo", "bar"])
    }

    func testNonUTF8BodyYieldsNoHit() {
        var bytes: [UInt8] = [0xFF, 0xFE, 0xFD]
        bytes.append(contentsOf: Array("{{kc:foo}}".utf8))
        let hits = PlaceholderScanner.scan(headers: [], uri: "/", body: Data(bytes))
        XCTAssertTrue(hits.isEmpty)
    }

    func testURIWithoutQueryHasNoQueryStringLocation() {
        let hits = PlaceholderScanner.scan(
            headers: [],
            uri: "/foo/{{kc:bar}}",
            body: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].location, .urlPath)
    }

    func testInvalidPlaceholderEmptyNameIgnored() {
        let hits = PlaceholderScanner.scan(
            headers: [("X", "{{kc:}}")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testInvalidPlaceholderNameTooLongIgnored() {
        let longName = String(repeating: "a", count: 65)
        let hits = PlaceholderScanner.scan(
            headers: [("X", "{{kc:\(longName)}}")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func testHeaderNameInLocationIsLowercased() {
        let hits = PlaceholderScanner.scan(
            headers: [("X-API-KEY", "{{kc:foo}}")],
            uri: "/",
            body: nil
        )
        XCTAssertEqual(hits[0].location, .header(name: "x-api-key"))
    }

    func testSnippetContainsPlaceholderLiteral() {
        let hits = PlaceholderScanner.scan(
            headers: [("Authorization", "Bearer {{kc:foo}} suffix")],
            uri: "/",
            body: nil
        )
        XCTAssertTrue(hits[0].snippet.contains("{{kc:foo}}"))
        XCTAssertLessThanOrEqual(hits[0].snippet.count, 256)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlaceholderScannerTests`
Expected: FAIL with "cannot find 'PlaceholderScanner' in scope"

- [ ] **Step 3: Create scanner**

Create `Sources/IrisKit/Placeholder/PlaceholderScanner.swift`:

```swift
import Foundation

public struct PlaceholderHit: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        case header(name: String)
        case urlPath
        case queryString
        case body
    }
    public let name: String
    public let location: Location
    public let snippet: String

    public init(name: String, location: Location, snippet: String) {
        self.name = name
        self.location = location
        self.snippet = snippet
    }
}

public enum PlaceholderScanner {
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: PlaceholderEngine.pattern)
    }()
    private static let snippetMaxLength = 256
    private static let snippetContextChars = 80

    public static func scan(
        headers: [(name: String, value: String)],
        uri: String,
        body: Data?
    ) -> [PlaceholderHit] {
        var hits: [PlaceholderHit] = []

        for (name, value) in headers {
            let location = PlaceholderHit.Location.header(name: name.lowercased())
            hits.append(contentsOf: scanString(name, location: location))
            hits.append(contentsOf: scanString(value, location: location))
        }

        let (path, query) = splitURI(uri)
        hits.append(contentsOf: scanString(path, location: .urlPath))
        if let query = query {
            hits.append(contentsOf: scanString(query, location: .queryString))
        }

        if let body = body, let bodyText = String(data: body, encoding: .utf8) {
            hits.append(contentsOf: scanString(bodyText, location: .body))
        }

        return hits
    }

    public static func scanString(_ text: String, location: PlaceholderHit.Location) -> [PlaceholderHit] {
        guard let regex = regex else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        return matches.compactMap { match -> PlaceholderHit? in
            guard match.numberOfRanges >= 2,
                let nameRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range(at: 0), in: text)
            else { return nil }
            let name = String(text[nameRange])
            let snippet = makeSnippet(text: text, around: fullRange)
            return PlaceholderHit(name: name, location: location, snippet: snippet)
        }
    }

    private static func splitURI(_ uri: String) -> (path: String, query: String?) {
        guard let qIdx = uri.firstIndex(of: "?") else { return (uri, nil) }
        let path = String(uri[..<qIdx])
        let query = String(uri[uri.index(after: qIdx)...])
        return (path, query)
    }

    private static func makeSnippet(text: String, around range: Range<String.Index>) -> String {
        let startOffset = max(
            text.distance(from: text.startIndex, to: range.lowerBound) - snippetContextChars,
            0
        )
        let endOffset = min(
            text.distance(from: text.startIndex, to: range.upperBound) + snippetContextChars,
            text.count
        )
        let snippetStart = text.index(text.startIndex, offsetBy: startOffset)
        let snippetEnd = text.index(text.startIndex, offsetBy: endOffset)
        let raw = String(text[snippetStart..<snippetEnd])
        let cleaned = raw.map { ch -> Character in
            if ch.isASCII, let scalar = ch.asciiValue, scalar < 0x20 || scalar == 0x7F {
                return "?"
            }
            return ch
        }
        let cleanedString = String(cleaned)
        if cleanedString.count > snippetMaxLength {
            return String(cleanedString.prefix(snippetMaxLength - 1)) + "…"
        }
        return cleanedString
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlaceholderScannerTests`
Expected: PASS, 12 tests

- [ ] **Step 5: Run swift-format**

Run: `swift-format lint --strict Sources/IrisKit/Placeholder/PlaceholderScanner.swift Tests/IrisKitTests/PlaceholderScannerTests.swift`
Expected: no output (clean)

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/Placeholder/PlaceholderScanner.swift Tests/IrisKitTests/PlaceholderScannerTests.swift
git commit -m "feat(phase-4): PlaceholderScanner — pure pre-substitution scan with hit locations"
```

---

## Task 2: `ExfilRuleEngine` skeleton + R1 (host mismatch)

**Files:**
- Create: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Create: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write failing tests for R1**

Create `Tests/IrisKitTests/ExfilRuleEngineTests.swift`:

```swift
import XCTest

@testable import IrisKit

final class ExfilRuleEngineTests: XCTestCase {
    private func makeEvaluator(
        secrets: [(name: String, allowedHosts: [String])] = [],
        maxPerMinute: Int = 60
    ) async throws -> ExfilRuleEngine {
        let store = InMemorySecretStore()
        for s in secrets {
            _ = try await store.add(
                Data("v".utf8),
                named: s.name,
                allowedHosts: s.allowedHosts,
                createdAt: Date()
            )
        }
        return ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinute: maxPerMinute)
    }

    private func ctx(
        host: String = "api.anthropic.com",
        method: String = "POST",
        path: String = "/v1/messages",
        contentType: String? = "application/json"
    ) -> RequestContext {
        RequestContext(host: host, method: method, path: path, contentType: contentType)
    }

    // MARK: R1

    func testR1HostMismatchBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "api.github.com"))
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .hostMismatch)
        XCTAssertEqual(alert.severity, .high)
        XCTAssertEqual(alert.secretName, "foo")
    }

    func testR1HostMatchAllows() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else {
            return XCTFail("expected allow")
        }
        XCTAssertEqual(resolvable.map(\.name), ["foo"])
    }

    func testR1UnknownSecretNotBlockedExcludedFromResolvable() async throws {
        let ev = try await makeEvaluator(secrets: [])
        let hits = [
            PlaceholderHit(name: "ghost", location: .header(name: "authorization"), snippet: "{{kc:ghost}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else {
            return XCTFail("expected allow with empty resolvable")
        }
        XCTAssertTrue(resolvable.isEmpty)
    }

    func testR1HostMatchIsCaseInsensitive() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "API.Anthropic.com"))
        guard case .allow = decision else { return XCTFail("expected allow") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: FAIL with "cannot find 'ExfilRuleEngine' in scope"

- [ ] **Step 3: Create engine skeleton with R1**

Create `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`:

```swift
import Foundation

public struct RequestContext: Sendable {
    public let host: String
    public let method: String
    public let path: String
    public let contentType: String?

    public init(host: String, method: String, path: String, contentType: String?) {
        self.host = host
        self.method = method
        self.path = path
        self.contentType = contentType
    }
}

public enum ExfilDecision: Sendable {
    case allow(resolvable: [PlaceholderHit])
    case block(alert: Alert, allHits: [PlaceholderHit])
}

public actor ExfilRuleEngine {
    private let secretStore: any SecretStore
    private let maxSubstitutionsPerMinute: Int

    public init(secretStore: any SecretStore, maxSubstitutionsPerMinute: Int) {
        self.secretStore = secretStore
        self.maxSubstitutionsPerMinute = maxSubstitutionsPerMinute
    }

    public func evaluate(
        hits: [PlaceholderHit],
        context: RequestContext
    ) async throws -> ExfilDecision {
        if hits.isEmpty {
            return .allow(resolvable: [])
        }

        let normalizedHost = context.host.lowercased()

        // Look up metadata for each hit name once.
        var metadataByName: [String: Secret] = [:]
        var knownHits: [PlaceholderHit] = []
        for hit in hits where metadataByName[hit.name] == nil {
            do {
                let secret = try await secretStore.secret(named: hit.name)
                metadataByName[hit.name] = secret
            } catch SecretStoreError.unknownSecret {
                // Unknown — excluded from resolvable, not blocked.
            }
        }
        for hit in hits where metadataByName[hit.name] != nil {
            knownHits.append(hit)
        }

        // R1 — host mismatch (high). Block whole request if any known hit's
        // host scope rejects this destination.
        for hit in knownHits {
            guard let secret = metadataByName[hit.name] else { continue }
            let allowed = Set(secret.allowedHosts.map { $0.lowercased() })
            if !allowed.contains(normalizedHost) {
                let alert = Alert(
                    severity: .high,
                    rule: .hostMismatch,
                    secretName: hit.name,
                    detectedAt: alertLocation(from: hit.location),
                    snippet: hit.snippet
                )
                return .block(alert: alert, allHits: hits)
            }
        }

        return .allow(resolvable: knownHits)
    }

    private func alertLocation(from location: PlaceholderHit.Location) -> Alert.Location {
        switch location {
        case .header: return .header
        case .urlPath: return .urlPath
        case .queryString: return .queryString
        case .body: return .body
        }
    }
}
```

- [ ] **Step 4: Run tests to verify R1 passes**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "feat(phase-4): ExfilRuleEngine — R1 host mismatch (SPECS §9.R1)"
```

---

## Task 3: R2 (non-canonical location)

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write failing R2 tests**

Append to `Tests/IrisKitTests/ExfilRuleEngineTests.swift` (inside the same class):

```swift
    // MARK: R2

    func testR2NonCanonicalHeaderBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "x-custom"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
        XCTAssertEqual(alert.severity, .high)
    }

    func testR2CanonicalAuthHeadersAllowed() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        for header in ["authorization", "x-api-key", "api-key", "x-auth-token"] {
            let hits = [
                PlaceholderHit(name: "foo", location: .header(name: header), snippet: "{{kc:foo}}")
            ]
            let decision = try await ev.evaluate(hits: hits, context: ctx())
            guard case .allow = decision else {
                return XCTFail("\(header) should be canonical")
            }
        }
    }

    func testR2HitInURLPathBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .urlPath, snippet: "/{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
        XCTAssertEqual(alert.detectedAt, .urlPath)
    }

    func testR2HitInQueryStringBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .queryString, snippet: "?x={{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
        XCTAssertEqual(alert.detectedAt, .queryString)
    }

    func testR2BodyOnGETBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx(method: "GET"))
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testR2BodyOnPOSTAllowed() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx(method: "POST"))
        guard case .allow = decision else {
            return XCTFail("R2 should not fire on POST body")
        }
    }
```

- [ ] **Step 2: Run tests to verify R2 tests fail**

Run: `swift test --filter ExfilRuleEngineTests/testR2`
Expected: FAIL

- [ ] **Step 3: Add R2 logic to engine**

In `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`, add the static set and extend the rule pipeline. Inside `ExfilRuleEngine`, add:

```swift
    private static let canonicalAuthHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-auth-token"
    ]

    private static func isNonCanonicalLocation(
        hit: PlaceholderHit,
        method: String
    ) -> Bool {
        switch hit.location {
        case .header(let name):
            return !canonicalAuthHeaders.contains(name)
        case .urlPath, .queryString:
            return true
        case .body:
            return method.uppercased() == "GET"
        }
    }
```

Then modify `evaluate(...)` — after the R1 block, add R2 logic immediately before `return .allow(resolvable: knownHits)`:

```swift
        // R2 — non-canonical location (high)
        for hit in knownHits {
            if Self.isNonCanonicalLocation(hit: hit, method: context.method) {
                let alert = Alert(
                    severity: .high,
                    rule: .nonCanonicalLocation,
                    secretName: hit.name,
                    detectedAt: alertLocation(from: hit.location),
                    snippet: hit.snippet
                )
                return .block(alert: alert, allHits: hits)
            }
        }
```

- [ ] **Step 4: Run tests to verify R2 passes**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: PASS, all R1 + R2 tests (10 total)

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "feat(phase-4): R2 non-canonical location (SPECS §9.R2)"
```

---

## Task 4: R3 (multiple distinct secrets)

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write failing R3 tests**

Append to `Tests/IrisKitTests/ExfilRuleEngineTests.swift`:

```swift
    // MARK: R3

    func testR3MultipleDistinctSecretsBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [
            ("foo", ["api.anthropic.com"]),
            ("bar", ["api.anthropic.com"]),
        ])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "bar", location: .header(name: "x-api-key"), snippet: "{{kc:bar}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .multipleSecrets)
        XCTAssertEqual(alert.severity, .medium)
        XCTAssertEqual(alert.secretName, "bar")  // alphabetically first
    }

    func testR3SameNameMultipleHitsAllowed() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "foo", location: .header(name: "x-api-key"), snippet: "{{kc:foo}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow = decision else {
            return XCTFail("same name multiple hits should not fire R3")
        }
    }

    func testR3CountsUnknownNames() async throws {
        // 1 known + 1 unknown = 2 distinct names → R3 fires.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "ghost", location: .header(name: "x-api-key"), snippet: "{{kc:ghost}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .multipleSecrets)
    }
```

- [ ] **Step 2: Run tests to verify R3 tests fail**

Run: `swift test --filter ExfilRuleEngineTests/testR3`
Expected: FAIL

- [ ] **Step 3: Add R3 logic**

In `evaluate(...)`, **before** the R1 loop (so R3 takes precedence by ordering only for severity composition tests later), no — keep R1 first per the design's ordering (R1 > R2 > R3 > R4 > R5). Add R3 **after** R2:

```swift
        // R3 — multiple distinct secrets (medium)
        let distinctNames = Set(hits.map(\.name))
        if distinctNames.count >= 2 {
            let triggeringName = distinctNames.sorted().first!
            let triggeringHit = hits.first { $0.name == triggeringName } ?? hits[0]
            let alert = Alert(
                severity: .medium,
                rule: .multipleSecrets,
                secretName: triggeringName,
                detectedAt: alertLocation(from: triggeringHit.location),
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: hits)
        }
```

Important: R3 looks at **all** hits, not just `knownHits`, per design §7.1.

- [ ] **Step 4: Run tests to verify R3 passes**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "feat(phase-4): R3 multiple distinct secrets (SPECS §9.R3)"
```

---

## Task 5: R4 (suspicious content type)

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write failing R4 tests**

Append to `Tests/IrisKitTests/ExfilRuleEngineTests.swift`:

```swift
    // MARK: R4

    func testR4TextPlainToIssuesPathBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "body {{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/repos/x/y/issues",
                contentType: "text/plain"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .suspiciousContentType)
        XCTAssertEqual(alert.severity, .medium)
    }

    func testR4FormUrlencodedToCommentsBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/comments/123",
                contentType: "application/x-www-form-urlencoded"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .suspiciousContentType)
    }

    func testR4JSONAPIPathAllowed() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.anthropic.com",
                method: "POST",
                path: "/v1/messages",
                contentType: "application/json"
            )
        )
        guard case .allow = decision else {
            return XCTFail("JSON API should not fire R4")
        }
    }

    func testR4ContentTypeWithCharsetParameter() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/issues",
                contentType: "text/plain; charset=utf-8"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .suspiciousContentType)
    }

    func testR4DoesNotFireWithoutBodyHit() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/issues",
                contentType: "text/plain"
            )
        )
        guard case .allow = decision else {
            return XCTFail("no body hit → R4 should not fire")
        }
    }
```

- [ ] **Step 2: Run tests to verify R4 tests fail**

Run: `swift test --filter ExfilRuleEngineTests/testR4`
Expected: FAIL

- [ ] **Step 3: Add R4 logic**

In `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`, inside the actor add:

```swift
    private static let suspiciousContentTypes: Set<String> = [
        "text/plain",
        "application/x-www-form-urlencoded",
        "multipart/form-data",
    ]

    private static let suspiciousPathFragments: [String] = [
        "/comments", "/issues", "/notes", "/messages", "/blob"
    ]

    private static func suspiciousContentTypeFires(
        hits: [PlaceholderHit],
        context: RequestContext
    ) -> PlaceholderHit? {
        guard let bodyHit = hits.first(where: { $0.location == .body }) else { return nil }
        guard let rawCT = context.contentType else { return nil }
        let baseType = rawCT.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard suspiciousContentTypes.contains(baseType) else { return nil }
        let path = context.path.lowercased()
        guard suspiciousPathFragments.contains(where: path.contains) else { return nil }
        return bodyHit
    }
```

In `evaluate(...)`, after R3 and before `return .allow(...)`, add:

```swift
        // R4 — suspicious content type (medium)
        if let triggeringHit = Self.suspiciousContentTypeFires(hits: hits, context: context) {
            let alert = Alert(
                severity: .medium,
                rule: .suspiciousContentType,
                secretName: triggeringHit.name,
                detectedAt: .body,
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: hits)
        }
```

- [ ] **Step 4: Run tests to verify R4 passes**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "feat(phase-4): R4 suspicious content type (SPECS §9.R4)"
```

---

## Task 6: R5 (volume anomaly) + `recordSubstitution`

**Files:**
- Modify: `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write failing R5 tests**

Append to `Tests/IrisKitTests/ExfilRuleEngineTests.swift`:

```swift
    // MARK: R5

    func testR5VolumeAnomalyFiresAtThreshold() async throws {
        let ev = try await makeEvaluator(
            secrets: [("foo", ["api.anthropic.com"])],
            maxPerMinute: 3
        )
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        // 3 successful substitutions recorded.
        for _ in 0..<3 {
            let decision = try await ev.evaluate(hits: hits, context: ctx())
            guard case .allow = decision else { return XCTFail("expected allow") }
            await ev.recordSubstitution(secretNames: ["foo"])
        }
        // 4th evaluate must block via R5.
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected R5 block")
        }
        XCTAssertEqual(alert.rule, .volumeAnomaly)
        XCTAssertEqual(alert.severity, .low)
    }

    func testR5DoesNotIncrementOnBlock() async throws {
        let ev = try await makeEvaluator(
            secrets: [("foo", ["api.anthropic.com"])],
            maxPerMinute: 2
        )
        let blockedHits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        // 5 blocked attempts via host mismatch should not bump R5 counter.
        for _ in 0..<5 {
            _ = try await ev.evaluate(hits: blockedHits, context: ctx(host: "api.evil.com"))
            // Caller does NOT call recordSubstitution on block.
        }
        // Now an allowed substitution should still go through (counter == 0).
        let decision = try await ev.evaluate(hits: blockedHits, context: ctx())
        guard case .allow = decision else {
            return XCTFail("counter must remain 0 after blocks")
        }
    }
```

- [ ] **Step 2: Run tests to verify R5 tests fail**

Run: `swift test --filter ExfilRuleEngineTests/testR5`
Expected: FAIL (`recordSubstitution` missing)

- [ ] **Step 3: Add R5 logic + sliding counter**

In `Sources/IrisKit/Placeholder/ExfilRuleEngine.swift`, add at file scope (above the actor):

```swift
struct SlidingMinuteCounter: Sendable {
    private var timestamps: [Date] = []

    mutating func record(at now: Date) {
        prune(before: now)
        timestamps.append(now)
    }

    mutating func count(at now: Date) -> Int {
        prune(before: now)
        return timestamps.count
    }

    private mutating func prune(before now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        timestamps.removeAll { $0 < cutoff }
    }
}
```

Inside the actor, add:

```swift
    private var volumeCounters: [String: SlidingMinuteCounter] = [:]

    public func recordSubstitution(secretNames: [String]) {
        let now = Date()
        for name in secretNames {
            var counter = volumeCounters[name] ?? SlidingMinuteCounter()
            counter.record(at: now)
            volumeCounters[name] = counter
        }
    }

    private func wouldExceedVolumeLimit(name: String) -> Bool {
        let now = Date()
        var counter = volumeCounters[name] ?? SlidingMinuteCounter()
        let willBe = counter.count(at: now) + 1
        volumeCounters[name] = counter  // persist any prune
        return willBe > maxSubstitutionsPerMinute
    }
```

In `evaluate(...)`, after R4 and before `return .allow(...)`, add:

```swift
        // R5 — volume anomaly (low)
        for hit in knownHits {
            if wouldExceedVolumeLimit(name: hit.name) {
                let alert = Alert(
                    severity: .low,
                    rule: .volumeAnomaly,
                    secretName: hit.name,
                    detectedAt: alertLocation(from: hit.location),
                    snippet: hit.snippet
                )
                return .block(alert: alert, allHits: hits)
            }
        }
```

- [ ] **Step 4: Run tests to verify R5 passes**

Run: `swift test --filter ExfilRuleEngineTests`
Expected: PASS (all R1–R5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/ExfilRuleEngine.swift Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "feat(phase-4): R5 volume anomaly + recordSubstitution (SPECS §9.R5)"
```

---

## Task 7: Severity composition (R1 takes precedence)

**Files:**
- Modify: `Tests/IrisKitTests/ExfilRuleEngineTests.swift`

- [ ] **Step 1: Write composition test**

Append:

```swift
    // MARK: Composition

    func testR1WinsOverR3WhenBothFire() async throws {
        // Two distinct secrets (R3 medium) + one of them is host-mismatched (R1 high).
        // Expected: alert reports R1, severity high (R1 ordered first in pipeline).
        let ev = try await makeEvaluator(secrets: [
            ("foo", ["api.anthropic.com"]),
            ("bar", ["api.anthropic.com"]),
        ])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "bar", location: .header(name: "x-api-key"), snippet: "{{kc:bar}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "api.github.com"))
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .hostMismatch)
        XCTAssertEqual(alert.severity, .high)
    }
```

- [ ] **Step 2: Run test**

Run: `swift test --filter ExfilRuleEngineTests/testR1WinsOverR3`
Expected: PASS (the existing pipeline checks R1 first, so this should already pass — confirms invariant)

- [ ] **Step 3: Commit**

```bash
git add Tests/IrisKitTests/ExfilRuleEngineTests.swift
git commit -m "test(phase-4): severity composition — R1 takes precedence over R3"
```

---

## Task 8: `PlaceholderEngine.substituteResolvable`

**Files:**
- Modify: `Sources/IrisKit/Placeholder/PlaceholderEngine.swift`
- Modify: `Tests/IrisKitTests/PlaceholderEngineTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/IrisKitTests/PlaceholderEngineTests.swift`:

```swift
    func testSubstituteResolvableReplacesOnlyAuthorizedHits() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO", "bar": "VALUE_BAR"])
        let authorizedHit = PlaceholderHit(
            name: "foo",
            location: .header(name: "authorization"),
            snippet: ""
        )
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:foo}}"), ("X-Other", "{{kc:bar}}")],
            uri: "/v1/messages",
            body: nil,
            resolvableHits: [authorizedHit]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
        XCTAssertEqual(payload.headers[0].value, "Bearer VALUE_FOO")
        XCTAssertEqual(payload.headers[1].value, "{{kc:bar}}")  // not authorized
    }

    func testSubstituteResolvableEmptyHitsReturnsVerbatim() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "Bearer {{kc:foo}}")],
            uri: "/v1/messages",
            body: nil,
            resolvableHits: []
        )
        XCTAssertEqual(payload.substituted, [])
        XCTAssertEqual(payload.headers[0].value, "Bearer {{kc:foo}}")
    }

    func testSubstituteResolvableSubstitutesInBody() async throws {
        let engine = try await makeEngine(with: ["foo": "VALUE_FOO"])
        let body = Data(#"{"key":"{{kc:foo}}"}"#.utf8)
        let hit = PlaceholderHit(name: "foo", location: .body, snippet: "")
        let payload = try await engine.substituteResolvable(
            headers: [],
            uri: "/",
            body: body,
            resolvableHits: [hit]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
        XCTAssertEqual(
            String(data: payload.body!, encoding: .utf8),
            #"{"key":"VALUE_FOO"}"#
        )
    }

    func testSubstituteResolvableReportsUnresolvedWhenSecretRemovedMidFlight() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data("V".utf8),
            named: "foo",
            allowedHosts: ["x"],
            createdAt: Date()
        )
        let engine = PlaceholderEngine(secretStore: store)
        // Resolve once to populate cache, then delete to simulate race.
        _ = try await engine.substituteResolvable(
            headers: [("Authorization", "{{kc:foo}}")],
            uri: "/",
            body: nil,
            resolvableHits: [PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "")]
        )
        try await store.delete(named: "foo")
        // Cache still has the value, so substitution still works — confirm.
        let payload = try await engine.substituteResolvable(
            headers: [("Authorization", "{{kc:foo}}")],
            uri: "/",
            body: nil,
            resolvableHits: [PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "")]
        )
        XCTAssertEqual(payload.substituted, ["foo"])
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter PlaceholderEngineTests/testSubstituteResolvable`
Expected: FAIL (method missing)

- [ ] **Step 3: Add `substituteResolvable` to engine**

In `Sources/IrisKit/Placeholder/PlaceholderEngine.swift`, add the result type at file scope:

```swift
public struct ResolvedRequestPayload: Sendable {
    public let headers: [(name: String, value: String)]
    public let uri: String
    public let body: Data?
    public let substituted: [String]
    public let unresolved: [String]
}
```

Note: `[(name: String, value: String)]` is not `Hashable`/`Equatable` by default but it is `Sendable` element-wise as a tuple of `String`. Swift treats tuples as Sendable when components are. Confirmed OK.

Inside the actor `PlaceholderEngine`, add:

```swift
    public func substituteResolvable(
        headers: [(name: String, value: String)],
        uri: String,
        body: Data?,
        resolvableHits: [PlaceholderHit]
    ) async throws -> ResolvedRequestPayload {
        guard !resolvableHits.isEmpty else {
            return ResolvedRequestPayload(
                headers: headers,
                uri: uri,
                body: body,
                substituted: [],
                unresolved: []
            )
        }

        // Resolve each unique authorized name once.
        let authorizedNames = Set(resolvableHits.map(\.name))
        var values: [String: Data] = [:]
        var unresolved: [String] = []
        for name in authorizedNames {
            do {
                values[name] = try await cachedValue(forName: name)
            } catch SecretStoreError.unknownSecret {
                unresolved.append(name)
            }
        }

        var substituted = Set<String>()
        let mutator: (String) -> String = { input in
            var result = input
            for (name, value) in values {
                let needle = "{{kc:\(name)}}"
                guard result.contains(needle) else { continue }
                guard let valueStr = String(data: value, encoding: .utf8) else { continue }
                result = result.replacingOccurrences(of: needle, with: valueStr)
                substituted.insert(name)
            }
            return result
        }

        var newHeaders: [(name: String, value: String)] = []
        newHeaders.reserveCapacity(headers.count)
        for (n, v) in headers {
            newHeaders.append((mutator(n), mutator(v)))
        }
        let newURI = mutator(uri)

        var newBody = body
        if let originalBody = body, let bodyText = String(data: originalBody, encoding: .utf8) {
            let transformed = mutator(bodyText)
            if transformed != bodyText {
                newBody = Data(transformed.utf8)
            }
        }

        return ResolvedRequestPayload(
            headers: newHeaders,
            uri: newURI,
            body: newBody,
            substituted: Array(substituted).sorted(),
            unresolved: unresolved
        )
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter PlaceholderEngineTests`
Expected: PASS (existing tests + new substituteResolvable tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Placeholder/PlaceholderEngine.swift Tests/IrisKitTests/PlaceholderEngineTests.swift
git commit -m "feat(phase-4): PlaceholderEngine.substituteResolvable — host-scoped substitution"
```

---

## Task 9: Wire `ExfilRuleEngine` + `onExfilAttempt` into `ProxyServer.Configuration`

**Files:**
- Modify: `Sources/IrisKit/Proxy/ProxyServer.swift`
- Modify: `Sources/irisd/Daemon.swift`

- [ ] **Step 1: Extend `ProxyServer.Configuration`**

In `Sources/IrisKit/Proxy/ProxyServer.swift`, modify the `Configuration` struct:

```swift
    public struct Configuration: Sendable {
        public var listenHost: String
        public var listenPort: Int
        public var allowedHosts: Set<String>
        public var upstreamPort: Int
        public var upstreamTrustRoots: NIOSSLTrustRoots
        public var maxSubstitutionsPerMinute: Int
        public var onExfilAttempt: ExfilAttemptPolicy

        public init(
            listenHost: String = "127.0.0.1",
            listenPort: Int = 8888,
            allowedHosts: Set<String>,
            upstreamPort: Int = 443,
            upstreamTrustRoots: NIOSSLTrustRoots = .default,
            maxSubstitutionsPerMinute: Int = 60,
            onExfilAttempt: ExfilAttemptPolicy = .blockAndNotify
        ) {
            self.listenHost = listenHost
            self.listenPort = listenPort
            self.allowedHosts = allowedHosts
            self.upstreamPort = upstreamPort
            self.upstreamTrustRoots = upstreamTrustRoots
            self.maxSubstitutionsPerMinute = maxSubstitutionsPerMinute
            self.onExfilAttempt = onExfilAttempt
        }
    }
```

Add a stored property for the evaluator below `placeholderEngine` (around line 41):

```swift
    let placeholderEngine: PlaceholderEngine
    let exfilRuleEngine: ExfilRuleEngine
```

In the `init`, after `placeholderEngine` assignment:

```swift
        self.placeholderEngine = PlaceholderEngine(secretStore: secretStore)
        self.exfilRuleEngine = ExfilRuleEngine(
            secretStore: secretStore,
            maxSubstitutionsPerMinute: configuration.maxSubstitutionsPerMinute
        )
```

- [ ] **Step 2: Pass values from `Daemon.start`**

In `Sources/irisd/Daemon.swift`, change the `proxyConfig` construction (around line 82):

```swift
        let proxyConfig = ProxyServer.Configuration(
            listenHost: listenHost,
            listenPort: listenPort,
            allowedHosts: allowedHosts,
            maxSubstitutionsPerMinute: config.security.maxSubstitutionsPerMinute,
            onExfilAttempt: config.security.onExfilAttempt
        )
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: build clean

- [ ] **Step 4: Run existing tests to verify nothing broke**

Run: `swift test`
Expected: 121 + new tests all green (no regression)

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/Proxy/ProxyServer.swift Sources/irisd/Daemon.swift
git commit -m "feat(phase-4): wire ExfilRuleEngine + on_exfil_attempt into ProxyServer.Configuration"
```

---

## Task 10: Refactor `MITMHandler.applySubstitution` → `processRequest`

**Files:**
- Modify: `Sources/IrisKit/Proxy/MITMHandler.swift`

This is the largest single refactor. It replaces `applySubstitution` with `processRequest` using the new scanner + evaluator pipeline, and emits Events including `.exfilBlocked`. No new files; integration tests come in Task 11.

- [ ] **Step 1: Build to baseline current state**

Run: `swift build && swift test`
Expected: clean

- [ ] **Step 2: Modify `MITMHandler.swift`**

Replace the body of `private func forwardRequest` and the `applySubstitution` static helper with the new pipeline. Patch:

Replace the `forwardRequest` and `applySubstitution` block (lines 76–257 approximately) with the following:

```swift
    private struct ProcessedRequest {
        let head: HTTPRequestHead
        let body: ByteBuffer?
        let outcome: Outcome

        enum Outcome {
            case bypassed
            case substituted(names: [String])
            case noMatch(unresolved: [String], nonUtf8: Bool, bodyTooLarge: Bool)
            case blocked(alert: Alert)
        }
    }

    private func forwardRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) {
        let server = self.server
        let host = self.host
        let channel = context.channel
        let eventLoop = context.eventLoop
        let startTime = Date()
        let bypass = server.isPaused

        eventLoop.makeFutureWithTask { () async throws -> (ProcessedRequest, UpstreamResponse) in
            let processed = try await Self.processRequest(
                head: head,
                body: body,
                evaluator: server.exfilRuleEngine,
                engine: server.placeholderEngine,
                logger: server.logger,
                host: host,
                bypass: bypass
            )
            if case .substituted(let names) = processed.outcome {
                server.logger.info(
                    "Substituted secrets",
                    metadata: [
                        "host": "\(host)",
                        "secrets": "\(names)",
                        "path": "\(processed.head.uri)",
                    ]
                )
            } else if case .blocked(let alert) = processed.outcome {
                server.logger.warning(
                    "Exfiltration attempt blocked",
                    metadata: [
                        "host": "\(host)",
                        "rule": "\(alert.rule.rawValue)",
                        "secret": "\(alert.secretName)",
                        "severity": "\(alert.severity.rawValue)",
                    ]
                )
                switch server.configuration.onExfilAttempt {
                case .blockOnly:
                    break
                case .blockAndNotify:
                    server.logger.warning(
                        "exfil notify intent (UI deferred to Phase 6)",
                        metadata: ["host": "\(host)"]
                    )
                case .blockNotifyPause:
                    server.logger.warning(
                        "auto-pausing daemon after exfil attempt",
                        metadata: ["host": "\(host)"]
                    )
                    server.setPaused(true)
                }
            }
            let upstream = try await server.upstreamClient.send(
                head: processed.head,
                body: processed.body,
                host: host,
                port: server.configuration.upstreamPort
            )
            return (processed, upstream)
        }.flatMap { (processed, upstream) -> EventLoopFuture<Void> in
            let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
            let event = Self.makeEvent(
                startTime: startTime,
                host: host,
                head: processed.head,
                upstream: upstream,
                duration: duration,
                outcome: processed.outcome
            )
            let ring = server.eventRing
            Task { await ring.append(event) }
            return Self.writeResponse(upstream, to: channel)
        }.whenComplete { result in
            if case .failure(let error) = result {
                let duration = UInt32(max(0, Date().timeIntervalSince(startTime) * 1_000))
                let event = Event(
                    timestamp: startTime,
                    kind: .error,
                    host: host,
                    method: head.method.rawValue,
                    path: head.uri,
                    durationMs: duration
                )
                let ring = server.eventRing
                Task { await ring.append(event) }
                server.logger.warning(
                    "Upstream forwarding failed",
                    metadata: ["host": "\(host)", "error": "\(error)"]
                )
            }
            channel.close(promise: nil)
        }
    }

    private static let bodyMaxBytes = 4 * 1024 * 1024

    private static func processRequest(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        evaluator: ExfilRuleEngine,
        engine: PlaceholderEngine,
        logger: Logger,
        host: String,
        bypass: Bool
    ) async throws -> ProcessedRequest {
        if bypass {
            return makeBypassedRequest(head: head, body: body)
        }

        // Strip Accept-Encoding (SPECS §7.5).
        var preparedHeaders = HTTPHeaders()
        for (name, value) in head.headers where name.lowercased() != "accept-encoding" {
            preparedHeaders.add(name: name, value: value)
        }

        // Body size cap (SPECS §7.2)
        var preparedBody = body
        var bodyTooLarge = false
        if let original = body {
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init)
            let declaredSize = contentLength ?? original.readableBytes
            if declaredSize > bodyMaxBytes {
                bodyTooLarge = true
                logger.warning(
                    "Body too large, skipping substitution scan",
                    metadata: ["host": "\(host)", "size": "\(declaredSize)"]
                )
            }
        }

        var preparedHead = HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: head.uri,
            headers: preparedHeaders
        )
        preparedHead.version = .http1_1

        if bodyTooLarge {
            return ProcessedRequest(
                head: preparedHead,
                body: preparedBody,
                outcome: .noMatch(unresolved: [], nonUtf8: false, bodyTooLarge: true)
            )
        }

        // Decode body into Data for scanning, with non-UTF-8 short-circuit.
        var bodyData: Data? = nil
        var nonUtf8 = false
        if let original = preparedBody {
            let data = Data(original.readableBytesView)
            if String(data: data, encoding: .utf8) == nil {
                nonUtf8 = true
            } else {
                bodyData = data
            }
        }

        if nonUtf8 {
            logger.debug("Body is non-UTF-8, skipping substitution scan", metadata: ["host": "\(host)"])
            return ProcessedRequest(
                head: preparedHead,
                body: preparedBody,
                outcome: .noMatch(unresolved: [], nonUtf8: true, bodyTooLarge: false)
            )
        }

        // Pass 1 — scan (pure).
        let headerPairs = preparedHeaders.map { (name: $0.name, value: $0.value) }
        let hits = PlaceholderScanner.scan(
            headers: headerPairs,
            uri: preparedHead.uri,
            body: bodyData
        )
        if hits.isEmpty {
            return ProcessedRequest(
                head: preparedHead,
                body: preparedBody,
                outcome: .noMatch(unresolved: [], nonUtf8: false, bodyTooLarge: false)
            )
        }

        // Build evaluator context.
        let (path, _) = splitURI(preparedHead.uri)
        let normalizedHost = host.lowercased()
        let contentType = preparedHeaders.first(name: "content-type")?.lowercased()
        let context = RequestContext(
            host: normalizedHost,
            method: preparedHead.method.rawValue,
            path: path,
            contentType: contentType
        )

        // Pass 2 — evaluate.
        let decision = try await evaluator.evaluate(hits: hits, context: context)
        switch decision {
        case .block(let alert, _):
            // Forward verbatim (Accept-Encoding stripped + HTTP/1.1 forced).
            return ProcessedRequest(
                head: preparedHead,
                body: preparedBody,
                outcome: .blocked(alert: alert)
            )
        case .allow(let resolvable):
            if resolvable.isEmpty {
                // All hits unknown (no R1 mismatch fired, just no value to fill).
                return ProcessedRequest(
                    head: preparedHead,
                    body: preparedBody,
                    outcome: .noMatch(unresolved: hits.map(\.name), nonUtf8: false, bodyTooLarge: false)
                )
            }

            // Pass 3 — substitute (only resolvable hits).
            let payload = try await engine.substituteResolvable(
                headers: headerPairs,
                uri: preparedHead.uri,
                body: bodyData,
                resolvableHits: resolvable
            )

            if payload.substituted.isEmpty {
                return ProcessedRequest(
                    head: preparedHead,
                    body: preparedBody,
                    outcome: .noMatch(
                        unresolved: payload.unresolved,
                        nonUtf8: false,
                        bodyTooLarge: false
                    )
                )
            }

            // Reassemble headers / URI / body.
            var newHeaders = HTTPHeaders()
            for (n, v) in payload.headers { newHeaders.add(name: n, value: v) }
            var newBody: ByteBuffer? = preparedBody
            if let mutated = payload.body, mutated != bodyData {
                var buf = ByteBufferAllocator().buffer(capacity: mutated.count)
                buf.writeBytes(mutated)
                newBody = buf
                if newHeaders.contains(name: "content-length") {
                    newHeaders.replaceOrAdd(name: "content-length", value: "\(mutated.count)")
                }
            }
            var newHead = HTTPRequestHead(
                version: .http1_1,
                method: preparedHead.method,
                uri: payload.uri,
                headers: newHeaders
            )
            newHead.version = .http1_1

            await evaluator.recordSubstitution(secretNames: payload.substituted)

            return ProcessedRequest(
                head: newHead,
                body: newBody,
                outcome: .substituted(names: payload.substituted)
            )
        }
    }

    private static func makeBypassedRequest(
        head: HTTPRequestHead,
        body: ByteBuffer?
    ) -> ProcessedRequest {
        var newHeaders = head.headers
        newHeaders.remove(name: "Accept-Encoding")
        var newHead = HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: head.uri,
            headers: newHeaders
        )
        newHead.version = .http1_1
        return ProcessedRequest(head: newHead, body: body, outcome: .bypassed)
    }

    private static func splitURI(_ uri: String) -> (path: String, query: String?) {
        guard let q = uri.firstIndex(of: "?") else { return (uri, nil) }
        return (String(uri[..<q]), String(uri[uri.index(after: q)...]))
    }

    private static func makeEvent(
        startTime: Date,
        host: String,
        head: HTTPRequestHead,
        upstream: UpstreamResponse,
        duration: UInt32,
        outcome: ProcessedRequest.Outcome
    ) -> Event {
        let status = Int(upstream.head.status.code)
        switch outcome {
        case .bypassed:
            return Event(
                timestamp: startTime,
                kind: .passThrough,
                host: host,
                method: head.method.rawValue,
                path: head.uri,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: []
            )
        case .substituted(let names):
            return Event(
                timestamp: startTime,
                kind: .substituted,
                host: host,
                method: head.method.rawValue,
                path: head.uri,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: names
            )
        case .noMatch:
            return Event(
                timestamp: startTime,
                kind: .noMatch,
                host: host,
                method: head.method.rawValue,
                path: head.uri,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: []
            )
        case .blocked(let alert):
            return Event(
                timestamp: startTime,
                kind: .exfilBlocked,
                host: host,
                method: head.method.rawValue,
                path: head.uri,
                statusCode: status,
                durationMs: duration,
                substitutedSecrets: [],
                alert: alert
            )
        }
    }
```

Notes for the engineer:

- `Event`'s init currently does NOT take `alert:` in Phase 2/3 — confirm by reading `Sources/IrisKit/Models/Event.swift`. If the init signature is `(timestamp:kind:host:method:path:statusCode:durationMs:substitutedSecrets:)` without `alert`, add the `alert:` parameter to a new `Event` init (defaulting `nil`), or use a memberwise + post-mutation if `alert` is `let`. SPECS §5.3 mandates `alert: Alert?` as a member.
- If `Event.init` needs to be extended, do that as part of this task — the modification is mechanical (add `alert: Alert? = nil` parameter, store it, update other call sites with default).
- `ConnectHandler` (passthrough §8.3) is **not** modified.

- [ ] **Step 3: Adjust `Event` init if needed**

If `swift build` complains about `Event` init not accepting `alert:`, modify `Sources/IrisKit/Models/Event.swift` to add `alert: Alert? = nil` with default to the existing init, preserving the `alert` stored property. Other call sites should compile unchanged (default value).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: all existing tests still pass (121 + new IrisKit ones)

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/Proxy/MITMHandler.swift Sources/IrisKit/Models/Event.swift
git commit -m "refactor(phase-4): MITMHandler — two-pass scan/evaluate/substitute + exfil event emission"
```

---

## Task 11: Integration test — exfil host mismatch end-to-end

**Files:**
- Modify: `Tests/IntegrationTests/ProxyEndToEndTests.swift`

- [ ] **Step 1: Add failing integration test**

Append to `Tests/IntegrationTests/ProxyEndToEndTests.swift`:

```swift
    func testHostMismatchEmitsExfilBlockedEventAndForwardsPlaceholder() async throws {
        let secretValue = "sk-real-XYZ"
        let secretName = "test_key"

        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],  // not "localhost"
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            maxSubstitutionsPerMinute: 60,
            onExfilAttempt: .blockOnly
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }
        defer {
            Task {
                try? await proxy.stop()
                try? await mock.stop()
            }
        }

        let client = try TestProxyClient(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            caManager: proxyCAManager
        )
        let response = try await client.post(
            host: "localhost",
            path: "/v1/x",
            headers: [("Authorization", "Bearer {{kc:\(secretName)}}")],
            body: nil
        )
        XCTAssertNotNil(response)

        // Upstream should have seen the literal placeholder, not the secret.
        let received = await mock.lastRequest()
        XCTAssertEqual(
            received?.headers["authorization"],
            "Bearer {{kc:\(secretName)}}"
        )

        let events = await proxy.eventRing.snapshot()
        let blocked = events.first(where: { $0.kind == .exfilBlocked })
        XCTAssertNotNil(blocked, "expected an exfilBlocked event")
        XCTAssertEqual(blocked?.alert?.rule, .hostMismatch)
        XCTAssertEqual(blocked?.alert?.severity, .high)
        XCTAssertEqual(blocked?.alert?.secretName, secretName)
        XCTAssertEqual(blocked?.substitutedSecrets, [])
    }
```

**Engineer note:** the `TestProxyClient.post` signature and the `MockUpstream.lastRequest()` API used above must match the existing helpers. If they differ, adapt to existing helpers (read `Tests/IntegrationTests/TestProxyClient.swift` and `Tests/IntegrationTests/MockUpstream.swift` first). The shape (headers dict + send + capture) is what matters; the exact method names follow the helper conventions.

- [ ] **Step 2: Run the integration test**

Run: `swift test --filter ProxyEndToEndTests/testHostMismatchEmitsExfilBlocked`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/ProxyEndToEndTests.swift
git commit -m "test(phase-4): integration — host mismatch emits exfilBlocked event"
```

---

## Task 12: Integration test — `block_notify_pause` auto-pauses daemon

**Files:**
- Modify: `Tests/IntegrationTests/ProxyEndToEndTests.swift`

- [ ] **Step 1: Add failing test**

Append to `ProxyEndToEndTests`:

```swift
    func testBlockNotifyPauseAutoPausesDaemon() async throws {
        let secretValue = "sk-real-XYZ"
        let secretName = "test_key"

        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            maxSubstitutionsPerMinute: 60,
            onExfilAttempt: .blockNotifyPause
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }
        defer {
            Task {
                try? await proxy.stop()
                try? await mock.stop()
            }
        }

        XCTAssertFalse(proxy.isPaused)

        let client = try TestProxyClient(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            caManager: proxyCAManager
        )
        _ = try await client.post(
            host: "localhost",
            path: "/v1/x",
            headers: [("Authorization", "Bearer {{kc:\(secretName)}}")],
            body: nil
        )

        // Allow event emission to complete.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(proxy.isPaused, "daemon must auto-pause after exfil with block_notify_pause")
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter ProxyEndToEndTests/testBlockNotifyPause`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/ProxyEndToEndTests.swift
git commit -m "test(phase-4): integration — block_notify_pause auto-pauses daemon"
```

---

## Task 13: Integration test — R5 volume anomaly

**Files:**
- Modify: `Tests/IntegrationTests/ProxyEndToEndTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
    func testVolumeAnomalyBlocksAfterThreshold() async throws {
        let secretValue = "sk-XYZ"
        let secretName = "test_key"

        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["localhost"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        _ = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)

        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO]),
            maxSubstitutionsPerMinute: 2,
            onExfilAttempt: .blockOnly
        )
        let proxy = ProxyServer(
            configuration: proxyConfig,
            secretStore: secretStore,
            caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }
        defer {
            Task {
                try? await proxy.stop()
                try? await mock.stop()
            }
        }

        let client = try TestProxyClient(
            proxyHost: "127.0.0.1",
            proxyPort: proxyPort,
            caManager: proxyCAManager
        )
        // Send 3 substituted requests; the 3rd must be blocked by R5.
        for _ in 0..<3 {
            _ = try await client.post(
                host: "localhost",
                path: "/v1/x",
                headers: [("Authorization", "Bearer {{kc:\(secretName)}}")],
                body: nil
            )
        }

        let events = await proxy.eventRing.snapshot()
        let substituted = events.filter { $0.kind == .substituted }
        let blocked = events.filter { $0.kind == .exfilBlocked && $0.alert?.rule == .volumeAnomaly }
        XCTAssertEqual(substituted.count, 2)
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.alert?.severity, .low)
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter ProxyEndToEndTests/testVolumeAnomaly`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/ProxyEndToEndTests.swift
git commit -m "test(phase-4): integration — R5 volume anomaly blocks after threshold"
```

---

## Task 14: Redaction invariance (alert snippet never contains secret value)

**Files:**
- Modify: `Tests/IrisKitTests/RedactionTests.swift`

- [ ] **Step 1: Add failing test**

Append to `Tests/IrisKitTests/RedactionTests.swift`:

```swift
    func testAlertSnippetNeverContainsSecretValue() async throws {
        let secretValue = "sk-supersecret-DO-NOT-LEAK"
        let secretName = "test_key"

        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )
        let evaluator = ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinute: 60)
        let hit = PlaceholderHit(
            name: secretName,
            location: .header(name: "x-custom"),
            snippet: "X-Custom: {{kc:\(secretName)}}"
        )
        let decision = try await evaluator.evaluate(
            hits: [hit],
            context: RequestContext(
                host: "api.anthropic.com",
                method: "POST",
                path: "/v1/x",
                contentType: "application/json"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertFalse(
            alert.snippet.contains(secretValue),
            "alert snippet must not contain secret value"
        )
        XCTAssertTrue(alert.snippet.contains("{{kc:\(secretName)}}"))
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter RedactionTests/testAlertSnippetNeverContainsSecretValue`
Expected: PASS (invariant holds by construction — scan is pre-substitution)

- [ ] **Step 3: Commit**

```bash
git add Tests/IrisKitTests/RedactionTests.swift
git commit -m "test(phase-4): redaction invariance — alert snippet never carries secret value"
```

---

## Task 15: Full build, lint, smoke, and PR prep

**Files:** none modified (verification only)

- [ ] **Step 1: Full build**

Run: `swift build`
Expected: clean

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: 121 baseline + new tests (~40+) all green, 0 failures

- [ ] **Step 3: Release build**

Run: `swift build -c release`
Expected: clean, 0 warnings

- [ ] **Step 4: swift-format lint**

Run: `swift-format lint --strict --recursive Sources Tests`
Expected: no output

- [ ] **Step 5: Manual smoke test**

Start the daemon with `--in-memory-secrets --in-memory-ca`:

```bash
.build/debug/irisd --config-path /tmp/iris-test.toml --in-memory-secrets --in-memory-ca &
```

Where `/tmp/iris-test.toml` contains:

```toml
[broker]
listen = "127.0.0.1:18888"
events_listen = "127.0.0.1:18899"
admin_socket = "/tmp/iris-test.sock"
log_level = "debug"
event_retention_days = 7
event_ring_size = 10000

[security]
on_exfil_attempt = "block_only"
max_substitutions_per_minute = 60

[[mitm_host]]
host = "api.anthropic.com"

[[mitm_host]]
host = "api.github.com"
```

Use an admin RPC `secret.add` to add a secret scoped to `api.anthropic.com`, then send (via `curl --proxy 127.0.0.1:18888 --cacert <ca pem>`) a request with `Authorization: Bearer {{kc:NAME}}` to `https://api.github.com/...` and confirm the event ring shows `.exfilBlocked` with `alert.rule == .hostMismatch`.

Kill the daemon: `pkill -f irisd`.

- [ ] **Step 6: Open PR with smoke checklist**

```bash
git push -u origin feat/phase-4-scoping-exfil

gh pr create --title "feat(phase-4): allowed_hosts scoping + exfiltration detection (R1-R5)" --body "$(cat <<'EOF'
## Summary

- Two-pass scan/evaluate/substitute pipeline in `MITMHandler`.
- New pure `PlaceholderScanner` + new actor `ExfilRuleEngine` (R1-R5 + sliding-minute counter).
- `PlaceholderEngine.substituteResolvable(...)` for host-scoped substitution.
- `on_exfil_attempt` enforcement: `block_only`, `block_and_notify` (log warn, UI notif deferred to Phase 6), `block_notify_pause` (auto-pauses daemon).
- Aucun secret value ne transite par les logs ni les events (invariant testé).

Design: `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md`
Plan: `docs/superpowers/plans/2026-05-25-phase-4-scoping-exfil.md`

## Smoke testing

- [ ] `swift build -c release` clean, 0 warnings
- [ ] `swift test` 121+ tests green
- [ ] `swift-format lint --strict --recursive Sources Tests` clean
- [ ] Daemon démarré avec config TOML inline ; secret ajouté via `secret.add` scopé à `api.anthropic.com`
- [ ] Requête `curl --proxy ... https://api.github.com/...` avec `Authorization: Bearer {{kc:NAME}}` → upstream reçoit le placeholder littéral (vérifié via mock ou log debug)
- [ ] Event ring contient `.exfilBlocked` avec `alert.rule == .hostMismatch`, `severity == .high`
- [ ] Requête vers `api.anthropic.com` avec le même secret → `.substituted`, secret réel forwardé
- [ ] `on_exfil_attempt = "block_notify_pause"` : après un block, `daemon.status` retourne `paused = true`
- [ ] `max_substitutions_per_minute = 2` + 3 requêtes autorisées : la 3e émet `.exfilBlocked(.volumeAnomaly)`

## SPECS coverage

- §8 Allowed-hosts scoping
- §9 Exfiltration detection (R1-R5)
- §10 Request flow (substituted + exfiltration traces)

## Hors scope (différés)

- RPC `rule.*`, `config.reload`, `events.clear` — Phase 4.x
- Notification macOS `UNUserNotificationCenter` — Phase 6 (vit dans l'app menu-bar)
- Persistance SQLite des events — Phase 5/6
EOF
)"
```

---

## Self-review

**Spec coverage check** (vs `docs/superpowers/specs/2026-05-25-phase-4-scoping-exfil-design.md`):

| Spec section          | Plan task(s) |
|-----------------------|--------------|
| §1 scope strict §8-§9 | Tasks 1–15   |
| §2 data flow          | Task 10 (pipeline dans MITMHandler) |
| §3.1 PlaceholderScanner | Task 1     |
| §3.2 ExfilRuleEngine  | Tasks 2–7    |
| §3.3 substituteResolvable | Task 8   |
| §3.4 SecretStore extension | N/A — existing `secret(named:)` used; design noted as correction |
| §3.5 MITMHandler refactor | Task 10  |
| §3.6 ProxyServer.Configuration wiring | Task 9 |
| §4 R1                 | Task 2       |
| §4 R2                 | Task 3       |
| §4 R3                 | Task 4       |
| §4 R4                 | Task 5       |
| §4 R5                 | Task 6       |
| §4 severity composition | Task 7    |
| §5 modèles, redaction | Task 14      |
| §6 on_exfil_attempt policy | Task 10 + Task 12 (integration) |
| §7 edge cases         | Tasks 2 (unknown secret), 4 (mixed known/unknown), 6 (R5 not on block), 12 (auto-pause) |
| §8 tests              | Tasks 1–14   |
| §9 perf budget        | N/A — no formal benchmark, smoke task in Task 15 |
| §10 plan de livraison | mapped above |

**Placeholder scan:** no "TBD", no "TODO", no "implement later". Engineer notes in Task 10/11 ask to consult helpers (`MockUpstream`, `TestProxyClient`, `Event.init` signature) — all reasonable read-then-adapt steps.

**Type consistency:**
- `PlaceholderHit` defined in Task 1, used identically in Tasks 2–8 + 14.
- `ExfilDecision.allow(resolvable:)` / `.block(alert: allHits:)` — same form everywhere.
- `RequestContext(host:method:path:contentType:)` — uniform across tasks.
- `ResolvedRequestPayload(headers:uri:body:substituted:unresolved:)` — used in Task 8 and Task 10.
- `ExfilAttemptPolicy.blockOnly / .blockAndNotify / .blockNotifyPause` — matches the existing `Config.swift` enum cases (verified).

**Note:** Tasks 11–13 references `MockUpstream.lastRequest()` and `TestProxyClient.post(host:path:headers:body:)`. The engineer must verify these helpers' actual APIs before invoking — the existing `Tests/IntegrationTests/MockUpstream.swift` and `Tests/IntegrationTests/TestProxyClient.swift` are the source of truth. If signatures differ, adapt locally without changing the test intent.
