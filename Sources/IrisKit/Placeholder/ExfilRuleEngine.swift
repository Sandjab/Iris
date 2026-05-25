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

    private static let canonicalAuthHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-auth-token",
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
}
