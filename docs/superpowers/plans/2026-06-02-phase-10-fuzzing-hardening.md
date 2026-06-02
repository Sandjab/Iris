# Phase 10 — Fuzzing Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durcir la substitution de secrets par un fuzzer maison déterministe (XCTest, zéro dépendance) qui attaque le pipeline réel `PlaceholderScanner → ExfilRuleEngine → PlaceholderEngine` et vérifie trois invariants — robustesse (I1), non-fuite (I2), non-bypass du scoping (I3) — plus la non-fuite à l'encodage des events SSE.

**Architecture:** Un PRNG seedé (SplitMix64) alimente un générateur de corpus adverse. Un harnais XCTest exécute le vrai pipeline sur chaque input (corpus nommé + 2000 itérations seedées) et asseoit les invariants. Tout vit sous `Tests/` — aucun code de production touché, aucun impact sur le binaire distribué.

**Tech Stack:** Swift 6, XCTest, `@testable import IrisKit`. Aucune dépendance tierce (décision brainstorming : SwiftCheck rejeté — non-`Sendable`, abandonné, shrinking sans valeur sur invariants binaires).

**Référence spec :** `docs/superpowers/specs/2026-06-02-phase-10-fuzzing-hardening-design.md`

---

## Contraintes transverses (lire avant de commencer)

- **Lint strict CI.** Le job `build-test` lance `swift-format lint --strict --recursive Sources Tests …`. Les fichiers de fuzz contiennent de longues chaînes adverses → **risque #1 de CI rouge**. Avant CHAQUE commit : `swift-format format -i <fichiers touchés>` puis `swift-format lint --strict <fichiers touchés>`. Indentation 4 espaces, lignes ≤ 120 colonnes.
- **Aucune sentinelle en clair dans les inputs générés.** La valeur de secret sentinelle ne doit JAMAIS être injectée littéralement dans un `FuzzInput` — uniquement stockée dans le `InMemorySecretStore`. Sinon I2 testerait une fuite de l'input, pas du système (test faux, Rule 9).
- **Déterminisme.** Seed constant (`AdversarialInputGenerator.seed`) + nombre d'itérations fixe. Reproduire un échec = relancer ; un échec sur l'itération N est identique à chaque run.

## File Structure

| Fichier | Responsabilité |
|---|---|
| `Tests/IrisKitTests/Fuzzing/SeededGenerator.swift` | PRNG SplitMix64 déterministe conforme à `RandomNumberGenerator`. Rien d'autre. |
| `Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift` | Type `FuzzInput`, corpus nommé statique, fonction de génération seedée. |
| `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift` | Helper `runPipeline`, assertions I1/I2/I3. |
| `Tests/IrisKitTests/RedactionTests.swift` (modifier) | Ajouter la couverture encodage event/SSE. |
| `Tests/IntegrationTests/ProxyExfilBlockTests.swift` | 1 test E2E : secret hors-scope → valeur n'atteint pas l'upstream. |

Signatures réelles confirmées (lues dans la source, ne pas réinventer) :

```swift
// PlaceholderScanner.swift
PlaceholderScanner.scan(headers: [(name: String, value: String)], uri: String, body: String?) -> [PlaceholderHit]
struct PlaceholderHit { let name: String; let location: Location; let snippet: String }
enum PlaceholderHit.Location { case header(name: String); case urlPath; case queryString; case body }

// ExfilRuleEngine.swift
struct RequestContext { init(host: String, method: String, path: String, contentType: String?) }
enum ExfilDecision { case allow(resolvable: [PlaceholderHit]); case block(alert: Alert, allHits: [PlaceholderHit]) }
actor ExfilRuleEngine { init(secretStore: any SecretStore, maxSubstitutionsPerMinuteProvider: @Sendable @escaping () -> Int)
    func evaluate(hits: [PlaceholderHit], context: RequestContext) async throws -> ExfilDecision }

// PlaceholderEngine.swift
actor PlaceholderEngine { init(secretStore: any SecretStore)
    func substituteResolvable(headers: [(name: String, value: String)], uri: String, body: Data?,
        resolvableHits: [PlaceholderHit]) async throws -> ResolvedRequestPayload }
struct ResolvedRequestPayload { let headers; let uri: String; let body: Data?; let substituted: [String]; let unresolved: [String] }

// InMemorySecretStore.swift
actor InMemorySecretStore: SecretStore { init()
    func add(_ value: Data, named name: String, allowedHosts: [String], createdAt: Date) async throws -> Secret }

// Event.swift / Alert.swift
struct Event: Codable { init(id: UUID = UUID(), timestamp: Date, kind: Kind, host: String, method: String,
    path: String, statusCode: Int? = nil, durationMs: UInt32? = nil, substitutedSecrets: [String] = [], alert: Alert? = nil) }
enum Event.Kind: String { case substituted, passThrough, noMatch, exfilBlocked, error }
struct Alert: Codable { init(severity: Severity, rule: ExfilRule, secretName: String, detectedAt: Location, snippet: String) }

// JSONRPC.swift — l'encodeur utilisé par EventsServer.writeSSEEvent pour le payload `data:`
JSONRPCCoder.makeEncoder() -> JSONEncoder
```

---

## Task 1: PRNG déterministe (SeededGenerator)

**Files:**
- Create: `Tests/IrisKitTests/Fuzzing/SeededGenerator.swift`
- Test: `Tests/IrisKitTests/Fuzzing/SeededGeneratorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IrisKitTests/Fuzzing/SeededGeneratorTests.swift`:

```swift
import XCTest

@testable import IrisKit

final class SeededGeneratorTests: XCTestCase {
    func testSameSeedProducesSameSequence() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        let seqA = (0..<100).map { _ in a.next() }
        let seqB = (0..<100).map { _ in b.next() }
        XCTAssertEqual(seqA, seqB)
    }

    func testDifferentSeedsProduceDifferentSequences() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        let seqA = (0..<100).map { _ in a.next() }
        let seqB = (0..<100).map { _ in b.next() }
        XCTAssertNotEqual(seqA, seqB)
    }

    func testConformsToRandomNumberGenerator() {
        var gen = SeededGenerator(seed: 7)
        // Must be usable with stdlib randomness APIs.
        let n = Int.random(in: 0..<10, using: &gen)
        XCTAssertTrue((0..<10).contains(n))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SeededGeneratorTests`
Expected: FAIL — `cannot find 'SeededGenerator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Tests/IrisKitTests/Fuzzing/SeededGenerator.swift`:

```swift
import Foundation

/// Deterministic SplitMix64 PRNG. Same seed → same sequence, so fuzz corpora
/// are 100% reproducible across runs (no flaky CI). `SystemRandomNumberGenerator`
/// is not seedable, hence this minimal in-house generator.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SeededGeneratorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/Fuzzing/SeededGenerator.swift Tests/IrisKitTests/Fuzzing/SeededGeneratorTests.swift
swift-format lint --strict Tests/IrisKitTests/Fuzzing/SeededGenerator.swift Tests/IrisKitTests/Fuzzing/SeededGeneratorTests.swift
git add Tests/IrisKitTests/Fuzzing/SeededGenerator.swift Tests/IrisKitTests/Fuzzing/SeededGeneratorTests.swift
git commit -m "test(phase-10): PRNG SplitMix64 déterministe pour le fuzzing"
```

---

## Task 2: Générateur de corpus adverse (AdversarialInputGenerator)

**Files:**
- Create: `Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift`
- Test: `Tests/IrisKitTests/Fuzzing/AdversarialInputGeneratorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IrisKitTests/Fuzzing/AdversarialInputGeneratorTests.swift`:

```swift
import Foundation
import XCTest

@testable import IrisKit

final class AdversarialInputGeneratorTests: XCTestCase {
    func testGenerationIsDeterministic() {
        let first = AdversarialInputGenerator.generate(count: 500)
        let second = AdversarialInputGenerator.generate(count: 500)
        XCTAssertEqual(first.map(\.label), second.map(\.label))
        XCTAssertEqual(first.map(\.uri), second.map(\.uri))
        XCTAssertEqual(first.map { $0.body }, second.map { $0.body })
    }

    func testNamedCorpusCoversKeyCategories() {
        let labels = Set(AdversarialInputGenerator.namedCorpus.map(\.label))
        for required in [
            "name-too-long", "name-empty", "thousands-occurrences",
            "unbalanced-braces", "nested-placeholder", "non-utf8-body",
            "control-chars", "unicode-name",
        ] {
            XCTAssertTrue(labels.contains(required), "missing corpus category: \(required)")
        }
    }

    func testGeneratedInputsNeverContainSentinel() {
        // The sentinel lives only in the secret store; it must never be baked
        // into an input (otherwise I2 would test input leakage, not system leakage).
        for input in AdversarialInputGenerator.generate(count: 2000) {
            XCTAssertFalse(input.uri.contains(AdversarialInputGenerator.sentinel))
            for (n, v) in input.headers {
                XCTAssertFalse(n.contains(AdversarialInputGenerator.sentinel))
                XCTAssertFalse(v.contains(AdversarialInputGenerator.sentinel))
            }
            if let body = input.body, let text = String(data: body, encoding: .utf8) {
                XCTAssertFalse(text.contains(AdversarialInputGenerator.sentinel))
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AdversarialInputGeneratorTests`
Expected: FAIL — `cannot find 'AdversarialInputGenerator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift`:

```swift
import Foundation

/// One synthetic request to feed through the substitution pipeline.
/// `body` is `Data?` so we can exercise non-UTF-8 bodies (the scanner takes
/// `String?` and the proxy passes `nil` for undecodable bytes — we reproduce
/// that contract in the harness).
struct FuzzInput {
    let headers: [(name: String, value: String)]
    let uri: String
    let body: Data?
    let label: String
}

/// Deterministic adversarial corpus targeting the `{{kc:NAME}}` grammar
/// (`[a-zA-Z0-9_-]{1,64}`) and its surroundings. Named cases document intent;
/// the seeded generator adds breadth.
enum AdversarialInputGenerator {
    /// Fixed seed → reproducible corpus. Changing this re-rolls every generated input.
    static let seed: UInt64 = 0xD1CE_5EED_1715_2026

    /// Secret name the pipeline knows about (populated in the harness store).
    static let knownSecretName = "leaky"
    /// Sentinel secret VALUE. Must never appear in any generated input.
    static let sentinel = "SENTINEL_VALUE_DO_NOT_LEAK_7Q3Z"

    private static let canonicalHeader = "x-api-key"
    private static let knownPlaceholder = "{{kc:\(knownSecretName)}}"

    // MARK: - Named regression corpus

    static let namedCorpus: [FuzzInput] = [
        FuzzInput(
            headers: [(canonicalHeader, "Bearer {{kc:\(String(repeating: "a", count: 65))}}")],
            uri: "/v1/messages", body: nil, label: "name-too-long"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "Bearer {{kc:\(String(repeating: "a", count: 64))}}")],
            uri: "/v1/messages", body: nil, label: "name-at-limit"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:}}")],
            uri: "/v1/messages", body: nil, label: "name-empty"
        ),
        FuzzInput(
            headers: [(canonicalHeader, String(repeating: knownPlaceholder, count: 5000))],
            uri: "/v1/messages", body: nil, label: "thousands-occurrences"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{ {{kc {{kc: kc:x}} }}}} {{")],
            uri: "/v1/messages", body: nil, label: "unbalanced-braces"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:{{kc:\(knownSecretName)}}}}")],
            uri: "/v1/messages", body: nil, label: "nested-placeholder"
        ),
        FuzzInput(
            headers: [(canonicalHeader, knownPlaceholder)],
            uri: "/v1/messages", body: Data([0xFF, 0xFE, 0x00, 0x80, 0xC0, 0x01]),
            label: "non-utf8-body"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:\u{0000}\u{0001}\u{007F}}}")],
            uri: "/v1/\u{0000}messages", body: nil, label: "control-chars"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:\u{0430}\u{0501}\u{200B}name}}")],
            uri: "/v1/messages", body: nil, label: "unicode-name"
        ),
        FuzzInput(
            headers: [("X-API-KEY", knownPlaceholder), ("AUTHORIZATION", knownPlaceholder)],
            uri: "/v1/messages", body: nil, label: "mixed-case-headers"
        ),
    ]

    // MARK: - Seeded generation

    private enum Placement: CaseIterable {
        case canonicalHeader, randomHeader, urlPath, queryString, body
    }

    private static let fragments: [String] = [
        knownPlaceholder,
        "{{kc:}}", "{{kc:" + String(repeating: "z", count: 70) + "}}",
        "{{kc", "kc:}}", "}}{{", "{{kc:{{kc:" + knownSecretName + "}}}}",
        "{{kc:\u{0000}}}", "{{kc:\u{200B}\u{0430}}}", "{{KC:" + knownSecretName + "}}",
        "{{kc:a-b_c}}", "  {{kc:" + knownSecretName + "}}  ",
    ]

    /// Generates `count` adversarial inputs deterministically.
    static func generate(count: Int) -> [FuzzInput] {
        var gen = SeededGenerator(seed: seed)
        var out: [FuzzInput] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let fragment = fragments[Int.random(in: 0..<fragments.count, using: &gen)]
            let repeatCount = Int.random(in: 1...4, using: &gen)
            let payload = String(repeating: fragment, count: repeatCount)
            let placement = Placement.allCases[Int.random(in: 0..<Placement.allCases.count, using: &gen)]
            out.append(make(placement: placement, payload: payload, index: i))
        }
        return out
    }

    private static func make(placement: Placement, payload: String, index: Int) -> FuzzInput {
        switch placement {
        case .canonicalHeader:
            return FuzzInput(
                headers: [(canonicalHeader, payload)], uri: "/v1/messages",
                body: nil, label: "gen-\(index)-canonical-header"
            )
        case .randomHeader:
            return FuzzInput(
                headers: [("x-custom-\(index % 7)", payload)], uri: "/v1/messages",
                body: nil, label: "gen-\(index)-random-header"
            )
        case .urlPath:
            return FuzzInput(
                headers: [], uri: "/v1/\(payload)/messages",
                body: nil, label: "gen-\(index)-url-path"
            )
        case .queryString:
            return FuzzInput(
                headers: [], uri: "/v1/messages?token=\(payload)",
                body: nil, label: "gen-\(index)-query"
            )
        case .body:
            return FuzzInput(
                headers: [("content-type", "application/json")], uri: "/v1/messages",
                body: Data(payload.utf8), label: "gen-\(index)-body"
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AdversarialInputGeneratorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift Tests/IrisKitTests/Fuzzing/AdversarialInputGeneratorTests.swift
swift-format lint --strict Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift Tests/IrisKitTests/Fuzzing/AdversarialInputGeneratorTests.swift
git add Tests/IrisKitTests/Fuzzing/AdversarialInputGenerator.swift Tests/IrisKitTests/Fuzzing/AdversarialInputGeneratorTests.swift
git commit -m "test(phase-10): générateur de corpus adverse déterministe"
```

---

## Task 3: Harnais + invariant I1 (robustesse)

**Files:**
- Create: `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift`

- [ ] **Step 1: Write the test (the harness + I1)**

Create `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift`:

```swift
import Foundation
import XCTest

@testable import IrisKit

final class PlaceholderFuzzTests: XCTestCase {
    private static let iterations = 2000

    /// Builds a store containing the known sentinel secret, scoped to
    /// `allowedHosts`. Default host matches the in-scope case.
    private func makeStore(allowedHosts: [String] = ["api.anthropic.com"]) async throws
        -> InMemorySecretStore
    {
        let store = InMemorySecretStore()
        _ = try await store.add(
            Data(AdversarialInputGenerator.sentinel.utf8),
            named: AdversarialInputGenerator.knownSecretName,
            allowedHosts: allowedHosts,
            createdAt: Date()
        )
        return store
    }

    /// Runs the real pipeline scan → evaluate → substitute, mirroring
    /// MITMHandler. Returns the decision and, when allowed, the payload.
    private func runPipeline(
        _ input: FuzzInput,
        store: InMemorySecretStore,
        host: String,
        method: String = "POST",
        contentType: String? = "application/json"
    ) async throws -> (decision: ExfilDecision, payload: ResolvedRequestPayload?) {
        let bodyText = input.body.flatMap { String(data: $0, encoding: .utf8) }
        let hits = PlaceholderScanner.scan(headers: input.headers, uri: input.uri, body: bodyText)
        let engine = ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { 100_000 })
        let context = RequestContext(
            host: host, method: method, path: input.uri, contentType: contentType
        )
        let decision = try await engine.evaluate(hits: hits, context: context)
        switch decision {
        case .allow(let resolvable):
            let pe = PlaceholderEngine(secretStore: store)
            let payload = try await pe.substituteResolvable(
                headers: input.headers, uri: input.uri, body: input.body, resolvableHits: resolvable
            )
            return (decision, payload)
        case .block:
            return (decision, nil)
        }
    }

    private func allInputs() -> [FuzzInput] {
        AdversarialInputGenerator.namedCorpus
            + AdversarialInputGenerator.generate(count: Self.iterations)
    }

    // MARK: I1 — robustness

    func testScanNeverCrashesOnAdversarialCorpus() {
        // Pure-sync scan over every input. A crash/hang here fails the run.
        for input in allInputs() {
            let bodyText = input.body.flatMap { String(data: $0, encoding: .utf8) }
            let hits = PlaceholderScanner.scan(
                headers: input.headers, uri: input.uri, body: bodyText
            )
            // Defense-in-depth bound: matches cannot exceed the input size.
            let inputChars =
                input.headers.reduce(0) { $0 + $1.name.count + $1.value.count }
                + input.uri.count + (bodyText?.count ?? 0)
            XCTAssertLessThanOrEqual(hits.count, inputChars + 1, "hit count must stay bounded for \(input.label)")
        }
    }

    func testFullPipelineNeverThrowsOnAdversarialCorpus() async throws {
        let store = try await makeStore()
        for input in allInputs() {
            _ = try await runPipeline(input, store: store, host: "api.anthropic.com")
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PlaceholderFuzzTests`
Expected: PASS — the production code is expected to be robust. If either test crashes or hangs, that is a **real I1 bug**: capture the failing `input.label`, switch to systematic-debugging, do NOT weaken the assertion.

- [ ] **Step 3: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
swift-format lint --strict Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git add Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git commit -m "test(phase-10): fuzz I1 — robustesse du parser et du pipeline"
```

---

## Task 4: Invariant I2 (non-fuite dans les artefacts d'observation)

**Files:**
- Modify: `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift`

- [ ] **Step 1: Add the I2 test**

Add these methods inside `final class PlaceholderFuzzTests` (after the I1 tests):

```swift
    // MARK: I2 — no secret value in observation artifacts

    /// Builds the Event exactly as MITMHandler would: `path` is the ORIGINAL
    /// (pre-substitution) URI, `substitutedSecrets` holds names, `alert` carries
    /// the placeholder snippet. The sentinel value must never appear in the
    /// encoded event (this is the source of truth for the SSE `data:` line).
    private func observationEvent(
        for input: FuzzInput,
        decision: ExfilDecision,
        payload: ResolvedRequestPayload?
    ) -> Event {
        switch decision {
        case .block(let alert, _):
            return Event(
                timestamp: Date(), kind: .exfilBlocked, host: "api.anthropic.com",
                method: "POST", path: input.uri, substitutedSecrets: [], alert: alert
            )
        case .allow:
            let substituted = payload?.substituted ?? []
            return Event(
                timestamp: Date(), kind: substituted.isEmpty ? .noMatch : .substituted,
                host: "api.anthropic.com", method: "POST", path: input.uri,
                substitutedSecrets: substituted, alert: nil
            )
        }
    }

    func testSentinelNeverLeaksIntoEncodedEvent() async throws {
        let store = try await makeStore()
        let encoder = JSONRPCCoder.makeEncoder()
        let sentinel = AdversarialInputGenerator.sentinel
        for input in allInputs() {
            let (decision, payload) = try await runPipeline(
                input, store: store, host: "api.anthropic.com"
            )
            let event = observationEvent(for: input, decision: decision, payload: payload)
            let json = try encoder.encode(event)
            let text = String(data: json, encoding: .utf8) ?? ""
            XCTAssertFalse(
                text.contains(sentinel),
                "sentinel leaked into event for input \(input.label)"
            )
        }
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter PlaceholderFuzzTests/testSentinelNeverLeaksIntoEncodedEvent`
Expected: PASS.

- [ ] **Step 3: Prove the test can fail (Rule 9 — do NOT commit this change)**

Temporarily change `path: input.uri` to `path: payload?.uri ?? input.uri` inside `observationEvent` (the post-substitution URI). Run the test again.
Expected: FAIL on inputs where the sentinel was substituted into the URI — proving the assertion bites.
Then **revert** the change (`git checkout -- Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift` if uncommitted, or undo by hand) and re-run to confirm PASS.

- [ ] **Step 4: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
swift-format lint --strict Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git add Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git commit -m "test(phase-10): fuzz I2 — non-fuite du secret dans les events encodés"
```

---

## Task 5: Invariant I3 (non-bypass du scoping)

**Files:**
- Modify: `Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift`

- [ ] **Step 1: Add the I3 tests**

Add these methods inside `final class PlaceholderFuzzTests`:

```swift
    // MARK: I3 — no substitution without explicit scope match

    /// Out-of-scope cases: a well-formed placeholder pointing at the known
    /// secret, where the request destination is NOT in the secret's
    /// `allowed_hosts` (R1) or sits in a non-canonical location (R2).
    private let outOfScopeCorpus: [(input: FuzzInput, host: String)] = [
        (
            FuzzInput(
                headers: [("x-api-key", "{{kc:leaky}}")], uri: "/v1/messages",
                body: nil, label: "r1-host-mismatch"
            ),
            "evil.example.com"
        ),
        (
            FuzzInput(
                headers: [("x-evil-header", "{{kc:leaky}}")], uri: "/v1/messages",
                body: nil, label: "r2-non-canonical-header"
            ),
            "api.anthropic.com"
        ),
        (
            FuzzInput(
                headers: [], uri: "/v1/{{kc:leaky}}/messages",
                body: nil, label: "r2-url-path"
            ),
            "api.anthropic.com"
        ),
        (
            FuzzInput(
                headers: [], uri: "/v1/messages?token={{kc:leaky}}",
                body: nil, label: "r2-query-string"
            ),
            "api.anthropic.com"
        ),
    ]

    func testOutOfScopePlaceholdersAreNeverSubstituted() async throws {
        // Store scopes the secret to api.anthropic.com only.
        let store = try await makeStore(allowedHosts: ["api.anthropic.com"])
        for (input, host) in outOfScopeCorpus {
            let (decision, payload) = try await runPipeline(input, store: store, host: host)
            guard case .block = decision else {
                return XCTFail("expected block for out-of-scope case \(input.label)")
            }
            XCTAssertNil(payload, "blocked request must not produce a substituted payload (\(input.label))")
        }
    }

    func testInScopeCanonicalPlaceholderIsSubstituted() async throws {
        // Positive control: the SAME secret IS resolved when host + location match.
        let store = try await makeStore(allowedHosts: ["api.anthropic.com"])
        let input = FuzzInput(
            headers: [("x-api-key", "{{kc:leaky}}")], uri: "/v1/messages",
            body: nil, label: "in-scope-canonical"
        )
        let (decision, payload) = try await runPipeline(input, store: store, host: "api.anthropic.com")
        guard case .allow = decision else {
            return XCTFail("expected allow for in-scope canonical case")
        }
        XCTAssertEqual(payload?.substituted, [AdversarialInputGenerator.knownSecretName])
    }
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PlaceholderFuzzTests`
Expected: PASS (all I1/I2/I3 tests). The positive control (`testInScopeCanonicalPlaceholderIsSubstituted`) guards against a vacuous I3 — it ensures the secret WOULD be substituted when in scope, so the out-of-scope assertions are meaningful (Rule 9).

- [ ] **Step 3: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
swift-format lint --strict Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git add Tests/IrisKitTests/Fuzzing/PlaceholderFuzzTests.swift
git commit -m "test(phase-10): fuzz I3 — non-bypass du scoping allowed_hosts/canonical"
```

---

## Task 6: Couverture encodage event/SSE (combler le trou de redaction)

**Files:**
- Modify: `Tests/IrisKitTests/RedactionTests.swift`

**Context:** `EventsServer.writeSSEEvent` encode l'event via `JSONRPCCoder.makeEncoder().encode(event)` puis l'enveloppe `event: <kind>\nid: <uuid>\ndata: <json>\n\n`. Le wrapping n'ajoute que `kind.rawValue` (enum) et l'UUID — aucun secret. La source de vérité d'une fuite SSE est donc l'**encodage JSON de l'Event**. On le teste directement, pour les deux kinds qui portent des données dérivées d'une requête contenant un secret : `.substituted` et `.exfilBlocked`.

- [ ] **Step 1: Add the encoding tests**

Add these methods inside `final class RedactionTests` (after the existing tests):

```swift
    func testEncodedSubstitutedEventNeverContainsSecretValue() throws {
        // CLAUDE.md §6.1: the SSE-encoded event must not carry secret values.
        // For a .substituted event, path is the ORIGINAL URI (placeholders),
        // substitutedSecrets holds names only.
        let secretValue = "sk-supersecret-DO-NOT-LEAK-SSE"
        let event = Event(
            timestamp: Date(), kind: .substituted, host: "api.anthropic.com",
            method: "POST", path: "/v1/messages?t={{kc:foo}}",
            statusCode: 200, durationMs: 12, substitutedSecrets: ["foo"], alert: nil
        )
        let json = try JSONRPCCoder.makeEncoder().encode(event)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(secretValue))
        XCTAssertTrue(text.contains("{{kc:foo}}"))
    }

    func testEncodedExfilBlockedEventNeverContainsSecretValue() throws {
        // For a .exfilBlocked event, the alert snippet is the placeholder literal.
        let secretValue = "sk-supersecret-DO-NOT-LEAK-SSE"
        let alert = Alert(
            severity: .high, rule: .hostMismatch, secretName: "foo",
            detectedAt: .header, snippet: "x-api-key: {{kc:foo}}"
        )
        let event = Event(
            timestamp: Date(), kind: .exfilBlocked, host: "evil.example.com",
            method: "POST", path: "/v1/messages", substitutedSecrets: [], alert: alert
        )
        let json = try JSONRPCCoder.makeEncoder().encode(event)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(secretValue))
        XCTAssertTrue(text.contains("{{kc:foo}}"))
    }
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter RedactionTests`
Expected: PASS (existing 7 + 2 new).

- [ ] **Step 3: Lint and commit**

```bash
swift-format format -i Tests/IrisKitTests/RedactionTests.swift
swift-format lint --strict Tests/IrisKitTests/RedactionTests.swift
git add Tests/IrisKitTests/RedactionTests.swift
git commit -m "test(phase-10): non-fuite à l'encodage des events SSE (substituted/exfilBlocked)"
```

---

## Task 7: Test d'intégration E2E — secret hors-scope ne fuit pas upstream

**Files:**
- Create: `Tests/IntegrationTests/ProxyExfilBlockTests.swift`

**Context (lu dans la source) :** `ProxyEndToEndTests.testSubstitutedValueReachesUpstream` montre le pattern in-process (`CAManager` + `MockUpstream.start` + `ProxyServer` + `TestProxyClient.send`). `MITMHandler.processRequest` confirme que sur décision `.block` (R1 host mismatch), l'`outcome` est `.blocked(alert:)` et la requête **n'est ni réassemblée ni forwardée** → l'upstream ne reçoit rien. Ce test réutilise le pattern avec un secret **hors-scope**.

- [ ] **Step 1: Write the test**

Create `Tests/IntegrationTests/ProxyExfilBlockTests.swift`:

```swift
import Crypto
import IrisKit
import NIO
import NIOHTTP1
import NIOSSL
import XCTest

final class ProxyExfilBlockTests: XCTestCase {
    func testOutOfScopeSecretIsBlockedAndNeverReachesUpstream() async throws {
        let secretValue = "sk-ant-must-not-leak-upstream"
        let secretName = "test_anthropic_key"

        // Secret is scoped to api.anthropic.com ONLY; the request targets
        // "localhost", so R1 (host mismatch) must block it.
        let secretStore = InMemorySecretStore()
        _ = try await secretStore.add(
            Data(secretValue.utf8),
            named: secretName,
            allowedHosts: ["api.anthropic.com"],
            createdAt: Date()
        )

        let proxyCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let proxyCACert = try await proxyCAManager.ensureCA()
        let mockCAManager = CAManager(keyStore: InMemoryCAKeyStore())
        let mockCACert = try await mockCAManager.ensureCA()

        let mock = try await MockUpstream.start(host: "localhost", caManager: mockCAManager)
        let mockCANIO = try NIOSSLCertificate(bytes: Array(mockCACert.derBytes), format: .der)
        let proxyConfig = ProxyServer.Configuration(
            listenHost: "127.0.0.1",
            listenPort: 0,
            allowedHosts: ["localhost"],  // MITM-whitelisted, but secret scope excludes it.
            upstreamPort: mock.port,
            upstreamTrustRoots: .certificates([mockCANIO])
        )
        let proxy = ProxyServer(
            configuration: proxyConfig, secretStore: secretStore, caManager: proxyCAManager
        )
        let proxyAddress = try await proxy.start()
        guard let proxyPort = proxyAddress.port else {
            try? await proxy.stop()
            try? await mock.stop()
            return XCTFail("proxy did not bind")
        }

        let proxyCANIO = try NIOSSLCertificate(bytes: Array(proxyCACert.derBytes), format: .der)
        let client = TestProxyClient()

        var response: TestProxyClient.Response?
        var caughtError: Error?
        do {
            response = try await client.send(
                proxyHost: "127.0.0.1",
                proxyPort: proxyPort,
                targetHost: "localhost",
                targetPort: 443,
                method: .POST,
                path: "/v1/messages",
                headers: [
                    ("host", "localhost"),
                    ("x-api-key", "{{kc:\(secretName)}}"),
                    ("content-type", "application/json"),
                ],
                body: Data(#"{"prompt":"hi"}"#.utf8),
                trustingCAs: [proxyCANIO]
            )
        } catch {
            caughtError = error
        }

        try? await proxy.stop()
        try? await mock.stop()

        // Core invariant (I3 at the wire): the real secret value never reached
        // the upstream. The proxy blocked the request before forwarding.
        let received = await mock.receivedRequestIfAny()
        XCTAssertNil(
            received,
            "blocked request must not reach upstream"
        )

        // Whatever the client got (proxy error response or a dropped connection),
        // it must NOT be the mock's success body.
        if let response = response {
            XCTAssertNotEqual(response.body, Data("OK".utf8))
        } else {
            XCTAssertNotNil(caughtError, "expected either a non-OK response or a connection error")
        }
    }
}
```

- [ ] **Step 2: Resolve the `MockUpstream` accessor (one-line investigation)**

The existing tests call `try await mock.receivedRequest()`, which likely *awaits* a request and would hang/throw when none arrives. This test needs a **non-blocking** "did anything arrive?" check.

Run: `grep -n "func receivedRequest\|receivedRequestIfAny\|recorded\|received" Tests/IntegrationTests/ProxyEndToEndTests.swift Tests/IntegrationTests/*.swift`

- If a non-blocking accessor already exists, use its exact name in place of `receivedRequestIfAny()`.
- If only the blocking `receivedRequest()` exists, add a non-blocking variant to `MockUpstream` (locate its definition first: `grep -rn "actor MockUpstream\|class MockUpstream\|func receivedRequest" Tests/IntegrationTests/`), e.g. returning the stored request or `nil` without awaiting. Keep the change additive — do not alter `receivedRequest()`'s existing behavior (other tests depend on it).

- [ ] **Step 3: Run the test**

Run: `swift test --filter ProxyExfilBlockTests`
Expected: PASS. If it hangs, the accessor is still blocking — fix Step 2. If the secret value DID reach upstream, that is a **real I3 bug at the wire** — switch to systematic-debugging, do not weaken the assertion.

- [ ] **Step 4: Lint and commit**

```bash
swift-format format -i Tests/IntegrationTests/ProxyExfilBlockTests.swift
swift-format lint --strict Tests/IntegrationTests/ProxyExfilBlockTests.swift
git add -A Tests/IntegrationTests/
git commit -m "test(phase-10): E2E — secret hors-scope bloqué, jamais forwardé upstream"
```

---

## Task 8: Vérification finale, mesure du coût, push, PR

**Files:** none (verification + integration)

- [ ] **Step 1: Full lint**

Run: `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp`
Expected: no output (clean). Fix any reported file with `swift-format format -i <file>`.

- [ ] **Step 2: Full build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Full test suite + time the fuzz**

Run: `time swift test`
Expected: all tests pass (existing + the new fuzz/encoding/E2E). Note the wall-clock.
- If the run is meaningfully slower (e.g. the fuzz adds more than a few seconds), reduce `PlaceholderFuzzTests.iterations` from 2000 (e.g. to 1000), re-run, and record the chosen value — **do not silently cap; mention it in the PR description** (design §5: no silent truncation).

- [ ] **Step 4: Push the branch**

```bash
git push -u origin feat/phase-10-fuzzing-hardening
```

- [ ] **Step 5: Open the PR with a smoke-testing checklist**

```bash
gh pr create --base main --head feat/phase-10-fuzzing-hardening \
  --title "test(phase-10): fuzzing hardening du parser de placeholder" \
  --body "$(cat <<'EOF'
## Résumé

Phase 10 — hardening par fuzzer maison déterministe (zéro dépendance). Attaque le pipeline réel scan → evaluate → substitute et vérifie I1 (robustesse), I2 (non-fuite), I3 (non-bypass du scoping), plus la non-fuite à l'encodage des events SSE.

Spec : `docs/superpowers/specs/2026-06-02-phase-10-fuzzing-hardening-design.md`

Aucun code de production touché — tout vit sous `Tests/`. Le job `xcode-build` (macos-15) n'est pas affecté (il ne build que l'app).

## Smoke testing

- [ ] `swift build` passe
- [ ] `swift test` passe (suite complète, sans régression)
- [ ] `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp` propre
- [ ] Le fuzz I1/I2/I3 s'exécute en un temps raisonnable (nombre d'itérations retenu : 2000 sauf mention contraire)
- [ ] CI vert : job `build-test` (macos-14) ET `xcode-build` (macos-15)
- [ ] Démonstration Rule 9 effectuée localement : casser temporairement un invariant fait rougir le fuzz (I2 path post-substitution ; I3 positive control)
EOF
)"
```

- [ ] **Step 6: Poll Gemini review per CLAUDE.md §8**

Lancer le polling Gemini (`/loop 30s …`) selon la procédure CLAUDE.md §8. Pour chaque commentaire : appliquer + répondre en référençant le commit, ou refuser factuellement. (Note : Gemini consumer est en sunset le 17 juillet 2026 ; si la review n'arrive pas, ne pas bloquer.)

- [ ] **Step 7: Merge (après confirmation explicite de l'utilisateur)**

Conditions : commentaires Gemini traités, CI vert, checklist smoke cochée. NE PAS merger sans accord explicite. Stratégie : `gh pr merge --squash`.

---

## Self-Review

**Spec coverage:**
- Périmètre « PRNG déterministe seedé » → Task 1. ✓
- « Générateur de corpus adverse » (toutes les catégories du §3) → Task 2. ✓
- « Harnais exécutant le vrai pipeline + I1/I2/I3 » → Tasks 3/4/5. ✓
- « Combler le trou redaction encodage SSE » → Task 6 (+ I2 fuzz en Task 4). ✓
- « 1 test d'intégration ciblé réutilisant le harnais » → Task 7. ✓
- « Critère §5 : un invariant cassé fait échouer le fuzz » → Task 4 Step 3 (I2) + Task 5 positive control (I3). ✓
- Hors-scope (deps, perf, autres parsers) → respecté ; aucune tâche n'y touche. ✓

**Placeholder scan:** Aucune étape « TODO/handle edge cases ». Task 7 Step 2 est une investigation ciblée d'une ligne (nom d'accesseur `MockUpstream`), pas un placeholder de logique — c'est le seul point non figé, et il est explicitement balisé avec la commande exacte pour le résoudre.

**Type consistency:** `SeededGenerator(seed:)`, `AdversarialInputGenerator.{seed,sentinel,knownSecretName,namedCorpus,generate(count:)}`, `FuzzInput.{headers,uri,body,label}`, `runPipeline(_:store:host:method:contentType:)`, `observationEvent(for:decision:payload:)` — noms cohérents entre Tasks 1→7. Signatures du pipeline (`scan`, `evaluate`, `substituteResolvable`, `InMemorySecretStore.add`, `Event`/`Alert` inits, `JSONRPCCoder.makeEncoder`) recopiées verbatim de la source.

**Incertitude résiduelle assumée (Rule 8/12) :** le nom exact de l'accesseur non-bloquant de `MockUpstream` (Task 7 Step 2) — résolu par grep au moment de l'implémentation, avec fallback (ajout additif) documenté.
