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
            host: host,
            method: method,
            path: input.uri,
            contentType: contentType
        )
        let decision = try await engine.evaluate(hits: hits, context: context)
        switch decision {
        case .allow(let resolvable):
            let pe = PlaceholderEngine(secretStore: store)
            let payload = try await pe.substituteResolvable(
                headers: input.headers,
                uri: input.uri,
                body: input.body,
                resolvableHits: resolvable
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
        for input in allInputs() {
            let bodyText = input.body.flatMap { String(data: $0, encoding: .utf8) }
            let hits = PlaceholderScanner.scan(
                headers: input.headers,
                uri: input.uri,
                body: bodyText
            )
            let inputChars =
                input.headers.reduce(0) { $0 + $1.name.count + $1.value.count }
                + input.uri.count + (bodyText?.count ?? 0)
            XCTAssertLessThanOrEqual(
                hits.count,
                inputChars + 1,
                "hit count must stay bounded for \(input.label)"
            )
        }
    }

    func testFullPipelineNeverThrowsOnAdversarialCorpus() async throws {
        let store = try await makeStore()
        for input in allInputs() {
            _ = try await runPipeline(input, store: store, host: "api.anthropic.com")
        }
    }
}
