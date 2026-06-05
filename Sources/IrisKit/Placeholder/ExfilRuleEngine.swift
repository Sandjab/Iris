import Foundation
import Logging

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
    private let logger: Logger
    private var volumeCounters: [String: SlidingMinuteCounter] = [:]

    /// Initialise with a provider closure so the threshold can be hot-reloaded
    /// without recreating the engine. The closure is called on every volume check.
    ///
    /// `logger` defaults to a silent (`info`-level) logger so test sites that do
    /// not care about diagnostics are unaffected. The proxy passes its own logger
    /// so the per-request hit inventory (a `debug` line) surfaces under
    /// `--log-level debug`.
    public init(
        secretStore: any SecretStore,
        maxSubstitutionsPerMinuteProvider: @Sendable @escaping () -> Int,
        logger: Logger = Logger(label: "io.iris.exfil")
    ) {
        self.secretStore = secretStore
        self.maxSubstitutionsPerMinuteProvider = maxSubstitutionsPerMinuteProvider
        self.logger = logger
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

        // Diagnostic inventory (debug-gated, §6.1: names/locations/counts only,
        // never the substituted value nor the snippet). Lets an operator running
        // `--log-level debug` see exactly which placeholders a tool emits and
        // whether each is known/unknown — the data needed to reason about R3
        // over-blocking without exposing any secret.
        let inventory =
            effectiveHits
            .map {
                "\($0.name)@\(Self.locationDescription($0.location)):\(metadataByName[$0.name] != nil ? "known" : "unknown")"
            }
            .joined(separator: ", ")
        logger.debug(
            "Exfil hit inventory",
            metadata: [
                "host": "\(normalizedHost)",
                "method": "\(context.method)",
                "path": "\(context.path)",
                "distinctNames": "\(Set(effectiveHits.map(\.name)).count)",
                "hits": "\(inventory)",
            ]
        )

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
            if Self.isNonCanonicalLocation(hit: hit) {
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

        // R3 — multiple distinct KNOWN secrets (medium). Les noms inconnus ne
        // resolvent jamais (ne fuient pas) et la grammaire {{kc:...}} apparait
        // dans du texte ordinaire (la doc d'IRIS elle-meme) -> on ne les compte
        // pas. Aligne sur R1/R2/R5 qui cles deja sur knownHits.
        let distinctNames = Set(knownHits.map(\.name))
        if distinctNames.count >= 2 {
            guard let triggeringName = distinctNames.sorted().first else {
                return .allow(resolvable: knownHits)
            }
            let triggeringHit = knownHits.first { $0.name == triggeringName } ?? knownHits[0]
            let alert = Alert(
                severity: .medium,
                rule: .multipleSecrets,
                secretName: triggeringName,
                detectedAt: alertLocation(from: triggeringHit.location),
                snippet: triggeringHit.snippet
            )
            return .block(alert: alert, allHits: effectiveHits)
        }

        // R4 — suspicious content type (medium). Hits connus uniquement : un nom
        // inconnu ne resout jamais. NOTE : sur le chemin courant R2 (body
        // non-canonique) preempte R4 pour tout hit body connu — R4 ne fire donc
        // plus ; conservee pour la defense en profondeur et un futur allowlist
        // body-credential.
        if let triggeringHit = Self.suspiciousContentTypeFires(hits: knownHits, context: context) {
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

    /// Value-free location label for the diagnostic inventory. The header name
    /// is request metadata (e.g. `x-api-key`), never a secret value.
    private static func locationDescription(_ location: PlaceholderHit.Location) -> String {
        switch location {
        case .header(let name): return "header(\(name))"
        case .urlPath: return "path"
        case .queryString: return "query"
        case .body: return "body"
        }
    }

    private static let canonicalAuthHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "x-auth-token",
    ]

    private static func isNonCanonicalLocation(hit: PlaceholderHit) -> Bool {
        switch hit.location {
        case .header(let name):
            return !canonicalAuthHeaders.contains(name)
        case .urlPath, .queryString, .body:
            // Substitution reservee aux headers d'auth canoniques : query, path
            // et body sont tous non-canoniques. Un secret connu qui y apparait
            // est un signal d'exfil (bloque, forwarde litteral, alerte).
            return true
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
