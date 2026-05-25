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
}
