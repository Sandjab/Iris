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
        XCTAssertEqual(alert.secretName, "foo")  // alphabetical winner over { foo, ghost }
        XCTAssertEqual(alert.detectedAt, .header)
    }

    func testR3TiebreakWinnerCanBeUnknownName() async throws {
        // Known "zeta" and unknown "alpha" — alphabetical winner is the unknown.
        // Asserts the triggering hit lookup uses original `hits`, not `knownHits`.
        let ev = try await makeEvaluator(secrets: [("zeta", ["api.anthropic.com"])])
        let hits = [
            PlaceholderHit(name: "zeta", location: .header(name: "authorization"), snippet: "{{kc:zeta}}"),
            PlaceholderHit(name: "alpha", location: .queryString, snippet: "?x={{kc:alpha}}"),
        ]
        let decision = try await ev.evaluate(hits: hits, context: ctx())
        guard case .block(let alert, _) = decision else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(alert.rule, .multipleSecrets)
        XCTAssertEqual(alert.secretName, "alpha")
        XCTAssertEqual(alert.detectedAt, .queryString)
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
        XCTAssertEqual(alert.rule, .suspiciousContentType)
        XCTAssertEqual(alert.severity, .medium)
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
        XCTAssertEqual(alert.rule, .suspiciousContentType)
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

    func testR4NoContentTypeDoesNotFire() async throws {
        let ev = try await makeEvaluator(secrets: [("foo", ["api.github.com"])])
        let hits = [PlaceholderHit(name: "foo", location: .body, snippet: "{{kc:foo}}")]
        let decision = try await ev.evaluate(
            hits: hits,
            context: ctx(
                host: "api.github.com",
                method: "POST",
                path: "/issues",
                contentType: nil
            )
        )
        guard case .allow = decision else {
            return XCTFail("missing content-type → R4 should not fire")
        }
    }

    func testR4SuspiciousCTNonSuspiciousPathAllowed() async throws {
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
        guard case .allow = decision else {
            return XCTFail("suspicious CT alone shouldn't fire R4")
        }
    }

    func testR4NonSuspiciousCTSuspiciousPathAllowed() async throws {
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
        guard case .allow = decision else {
            return XCTFail("suspicious path alone shouldn't fire R4")
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
}
