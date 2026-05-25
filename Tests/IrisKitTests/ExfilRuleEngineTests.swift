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
