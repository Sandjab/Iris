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
        // Inclusive window: keep timestamps t with now-60 <= t <= now.
        let cutoff = now.addingTimeInterval(-60)
        timestamps.removeAll { $0 < cutoff }
    }
}

public actor ExfilRuleEngine {
    private let secretStore: any SecretStore
    private let maxSubstitutionsPerMinuteProvider: @Sendable () -> Int
    private var volumeCounters: [String: SlidingMinuteCounter] = [:]

    /// Initialise with a provider closure so the threshold can be hot-reloaded
    /// without recreating the engine. The closure is called on every volume check.
    public init(
        secretStore: any SecretStore,
        maxSubstitutionsPerMinuteProvider: @Sendable @escaping () -> Int
    ) {
        self.secretStore = secretStore
        self.maxSubstitutionsPerMinuteProvider = maxSubstitutionsPerMinuteProvider
    }

    public func recordSubstitution(secretNames: [String]) {
        let now = Date()
        for name in secretNames {
            var counter = volumeCounters[name] ?? SlidingMinuteCounter()
            counter.record(at: now)
            volumeCounters[name] = counter
        }
    }

    private func wouldExceedVolumeLimit(name: String) -> Bool {
        let limit = maxSubstitutionsPerMinuteProvider()
        let now = Date()
        guard var counter = volumeCounters[name] else {
            return 1 > limit
        }
        let willBe = counter.count(at: now) + 1
        volumeCounters[name] = counter  // persist prune
        return willBe > limit
    }

    public func evaluate(
        hits: [PlaceholderHit],
        context: RequestContext
    ) async throws -> ExfilDecision {
        if hits.isEmpty {
            return .allow(resolvable: [])
        }

        // SPECS §8.2: host comparison must ignore port. Strip at the
        // evaluator boundary as defense-in-depth in case a caller forwards
        // an `:authority`-style value (`host:port`).
        let hostWithoutPort =
            context.host
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? context.host
        let normalizedHost = hostWithoutPort.lowercased()

        // Look up metadata for each hit name once.
        var metadataByName: [String: Secret] = [:]
        for hit in hits where metadataByName[hit.name] == nil {
            do {
                let secret = try await secretStore.secret(named: hit.name)
                metadataByName[hit.name] = secret
            } catch SecretStoreError.unknownSecret {
                // Unknown — excluded from resolvable, not blocked.
            }
        }

        // Phase 6.2.x — quarantined secrets are inert: removed from the working
        // hit set entirely so they are neither substituted nor scored by any
        // exfil rule. No value is ever substituted for a quarantined secret, so
        // nothing can leak. Unknown names (no metadata) stay so R3 typo
        // detection is preserved.
        let effectiveHits = hits.filter { metadataByName[$0.name]?.quarantined != true }

        var knownHits: [PlaceholderHit] = []
        for hit in effectiveHits where metadataByName[hit.name] != nil {
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
                return .block(alert: alert, allHits: effectiveHits)
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
                return .block(alert: alert, allHits: effectiveHits)
            }
        }

        // R3 — multiple distinct secrets (medium). Counts all hits, including
        // unknown names (design §7.1): mixed known + typo is exactly the pattern
        // we want to flag.
        let distinctNames = Set(effectiveHits.map(\.name))
        if distinctNames.count >= 2 {
            guard let triggeringName = distinctNames.sorted().first else {
                return .allow(resolvable: knownHits)
            }
            let triggeringHit = effectiveHits.first { $0.name == triggeringName } ?? effectiveHits[0]
            let alert = Alert(
                severity: .medium,
                rule: .multipleSecrets,
                secretName: triggeringName,
                detectedAt: alertLocation(from: triggeringHit.location),
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: effectiveHits)
        }

        // R4 — suspicious content type (medium)
        if let triggeringHit = Self.suspiciousContentTypeFires(hits: effectiveHits, context: context) {
            let alert = Alert(
                severity: .medium,
                rule: .suspiciousContentType,
                secretName: triggeringHit.name,
                detectedAt: .body,
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: effectiveHits)
        }

        // R5 — volume anomaly (low). Checks only KNOWN hits because we count
        // successful substitutions, which only happen for known secrets.
        for hit in knownHits {
            if wouldExceedVolumeLimit(name: hit.name) {
                let alert = Alert(
                    severity: .low,
                    rule: .volumeAnomaly,
                    secretName: hit.name,
                    detectedAt: alertLocation(from: hit.location),
                    snippet: hit.snippet
                )
                return .block(alert: alert, allHits: effectiveHits)
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

    private static let suspiciousContentTypes: Set<String> = [
        "text/plain",
        "application/x-www-form-urlencoded",
        "multipart/form-data",
    ]

    private static let suspiciousPathFragments: [String] = [
        "/comments", "/issues", "/notes", "/messages", "/blob",
    ]

    private static func suspiciousContentTypeFires(
        hits: [PlaceholderHit],
        context: RequestContext
    ) -> PlaceholderHit? {
        guard let bodyHit = hits.first(where: { $0.location == .body }) else { return nil }
        guard let rawCT = context.contentType else { return nil }
        let baseType =
            rawCT
            .split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        guard suspiciousContentTypes.contains(baseType) else { return nil }
        let path = context.path.lowercased()
        guard suspiciousPathFragments.contains(where: path.contains) else { return nil }
        return bodyHit
    }
}
