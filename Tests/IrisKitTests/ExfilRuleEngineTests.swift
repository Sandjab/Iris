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
        return ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { maxPerMinute })
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
        guard case .block(let alert, let allHits) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(allHits.map(\.name), ["foo"])
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

    func testR1HostWithPortIsStrippedBeforeCompare() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(host: "api.anthropic.com:443")
        )
        guard case .allow = decision else {
            return XCTFail("host with port should match allowed_hosts entry without port")
        }
    }

    func testR1HostMatchIsCaseInsensitive() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "API.Anthropic.com"))
        guard case .allow = decision else { return XCTFail("expected allow") }
    }

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

    func testR2CanonicalHeaderMatchIsCaseInsensitive() async throws {
        // HTTP header names are case-insensitive (RFC 7230). A known secret in a
        // mixed-case canonical auth header must be allowed, not blocked by R2.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "X-API-Key"), snippet: "{{kc:foo}}")
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else {
            return XCTFail("mixed-case canonical header must be allowed")
        }
        XCTAssertEqual(resolvable.map(\.name), ["foo"])
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

    func testR2BodyOnPOSTBlocks() async throws {
        // Headers-only : un secret connu n'importe ou dans un body est un signal
        // d'exfil (forwarde litteral + alerte), jamais substitue.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx(method: "POST"))
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in POST body must block (body non-canonical)")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

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
        guard case .block(let alert, let allHits) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .multipleSecrets)
        XCTAssertEqual(alert.severity, .medium)
        XCTAssertEqual(alert.secretName, "bar")  // alphabetically first
        XCTAssertEqual(allHits.count, 2)
        XCTAssertEqual(allHits.map(\.name), ["foo", "bar"])
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

    func testR3IgnoresUnknownNames() async throws {
        // R3 ne compte que les secrets CONNUS (un env-dump de vrais credentials).
        // Un nom inconnu ne resout jamais -> ne peut fuiter -> ne doit pas bloquer.
        // C'est le fix du faux positif de la doc {{kc:NAME}}.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "ghost", location: .header(name: "x-api-key"), snippet: "{{kc:ghost}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else {
            return XCTFail("1 known + 1 unknown -> R3 must not fire (known-only)")
        }
        XCTAssertEqual(resolvable.map(\.name), ["foo"])
    }

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
        guard case .block(let alert, let allHits) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
        XCTAssertEqual(alert.severity, .high)
        XCTAssertEqual(alert.secretName, "foo")
        XCTAssertEqual(alert.detectedAt, .body)
        XCTAssertEqual(allHits.count, 1)
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
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testR4MultipartToBlobBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/repos/x/y/blob/main",
                contentType: "multipart/form-data"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testKnownSecretInJSONBodyBlocks() async throws {
        // A2 : un secret connu dans un body JSON vers son propre host autorise
        // (ex. un PAT faufile dans un commentaire GitHub) etait silencieusement
        // substitue. R2 (body non-canonique) le bloque desormais.
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
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in JSON body must block")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
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
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
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

    func testKnownSecretInBodyNoContentTypeBlocks() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(host: "api.github.com", method: "POST", path: "/issues", contentType: nil)
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in body must block regardless of content-type")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testR4SuspiciousCTNonSuspiciousPathBlocksViaR2() async throws {
        // Post-Task1 : le body est desormais non-canonique pour tout secret connu.
        // R2 preempte R4 : meme si le CT seul n'est pas suffisant pour R4, R2 bloque.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.anthropic.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.anthropic.com",
                method: "POST",
                path: "/v1/complete",
                contentType: "text/plain"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in body must block via R2 (body non-canonical)")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testR4NonSuspiciousCTSuspiciousPathBlocksViaR2() async throws {
        // Post-Task1 : le body est desormais non-canonique pour tout secret connu.
        // R2 preempte R4 : meme si le path seul n'est pas suffisant pour R4, R2 bloque.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/issues",
                contentType: "application/json"
            )
        )
        guard case .block(let alert, _) = decision else {
            return XCTFail("known secret in body must block via R2 (body non-canonical)")
        }
        XCTAssertEqual(alert.rule, .nonCanonicalLocation)
    }

    func testR4IgnoresUnknownBodyName() async throws {
        // R4 cle sur les secrets connus uniquement. Un placeholder inconnu dans
        // un body suspect ne doit pas bloquer (il ne resout jamais). R2 ne le
        // bloque pas non plus (R2 cle sur les connus) -> requete autorisee.
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "ghost", location: .body, snippet: "{{kc:ghost}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(host: "api.github.com", method: "POST", path: "/issues", contentType: "text/plain")
        )
        guard case .allow = decision else {
            return XCTFail("unknown body name must not fire R4 (known-only)")
        }
    }

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
        XCTAssertEqual(alert.secretName, "foo")
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

    // MARK: Composition

    func testR1WinsOverR3WhenBothFire() async throws {
        // Two distinct secrets (R3 medium) + one of them is host-mismatched (R1 high).
        // Expected: alert reports R1 (.hostMismatch), severity .high (R1 in pipeline order).
        let ev = try await makeEvaluator(secrets: [
            ("foo", ["api.anthropic.com"]),
            ("bar", ["api.anthropic.com"]),
        ])
        let hits = [
            PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}"),
            PlaceholderHit(name: "bar", location: .header(name: "x-api-key"), snippet: "{{kc:bar}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "api.github.com"))
        guard case .block(let alert, let allHits) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .hostMismatch)
        XCTAssertEqual(alert.severity, .high)
        XCTAssertEqual(allHits.count, 2)
    }

    // MARK: Quarantine (Phase 6.2.x — inert semantics)

    private func makeStoreAndEngine(
        secrets: [(name: String, allowedHosts: [String], quarantined: Bool)],
        maxPerMinute: Int = 60
    ) async throws -> ExfilRuleEngine {
        let store = InMemorySecretStore()
        for s in secrets {
            _ = try await store.add(Data("v".utf8), named: s.name, allowedHosts: s.allowedHosts, createdAt: Date())
            if s.quarantined { _ = try await store.setQuarantined(true, named: s.name) }
        }
        return ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { maxPerMinute })
    }

    func testQuarantinedNotResolvableOnAllowedHost() async throws {
        let ev = try await makeStoreAndEngine(secrets: [("foo", ["api.anthropic.com"], true)])
        let hits = [PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else { return XCTFail("expected allow") }
        XCTAssertTrue(resolvable.isEmpty, "quarantined secret must not be resolvable")
    }

    func testQuarantinedNotBlockedOnDisallowedHost() async throws {
        // A non-quarantined secret here would block via R1 hostMismatch.
        let ev = try await makeStoreAndEngine(secrets: [("foo", ["api.anthropic.com"], true)])
        let hits = [PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx(host: "api.github.com"))
        guard case .allow(let resolvable) = decision else { return XCTFail("expected allow (inert), not block") }
        XCTAssertTrue(resolvable.isEmpty)
    }

    func testQuarantinedDoesNotTriggerR3WithActiveSecret() async throws {
        let ev = try await makeStoreAndEngine(secrets: [
            ("active", ["api.anthropic.com"], false),
            ("quar", ["api.anthropic.com"], true),
        ])
        let hits = [
            PlaceholderHit(name: "active", location: .header(name: "authorization"), snippet: "{{kc:active}}"),
            PlaceholderHit(name: "quar", location: .header(name: "x-api-key"), snippet: "{{kc:quar}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else { return XCTFail("expected allow, not R3 block") }
        XCTAssertEqual(resolvable.map(\.name), ["active"])
    }

    func testUnquarantineRestoresResolvable() async throws {
        let store = InMemorySecretStore()
        _ = try await store.add(Data("v".utf8), named: "foo", allowedHosts: ["api.anthropic.com"], createdAt: Date())
        _ = try await store.setQuarantined(true, named: "foo")
        _ = try await store.setQuarantined(false, named: "foo")
        let ev = ExfilRuleEngine(secretStore: store, maxSubstitutionsPerMinuteProvider: { 60 })
        let hits = [PlaceholderHit(name: "foo", location: .header(name: "authorization"), snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .allow(let resolvable) = decision else { return XCTFail("expected allow") }
        XCTAssertEqual(resolvable.map(\.name), ["foo"])
    }
}
