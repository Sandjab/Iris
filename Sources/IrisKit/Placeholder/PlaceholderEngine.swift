import Foundation

public struct SubstitutionOutcome: Sendable, Equatable {
    public let output: Data
    public let substituted: [String]
    public let unresolved: [String]
    /// True when the input could not be decoded as UTF-8 and was passed through unchanged (SPECS §7.4).
    public let nonUtf8: Bool

    public init(output: Data, substituted: [String], unresolved: [String], nonUtf8: Bool = false) {
        self.output = output
        self.substituted = substituted
        self.unresolved = unresolved
        self.nonUtf8 = nonUtf8
    }
}

public struct ResolvedRequestPayload: Sendable {
    public let headers: [(name: String, value: String)]
    public let uri: String
    public let body: Data?
    public let substituted: [String]
    public let unresolved: [String]

    public init(
        headers: [(name: String, value: String)],
        uri: String,
        body: Data?,
        substituted: [String],
        unresolved: [String]
    ) {
        self.headers = headers
        self.uri = uri
        self.body = body
        self.substituted = substituted
        self.unresolved = unresolved
    }
}

public actor PlaceholderEngine {
    private let secretStore: any SecretStore

    // MARK: - Secret value cache (SPECS §4.1: TTL 5 min, max 32 entries)

    private struct CacheEntry: Sendable {
        let value: Data
        let expiresAt: Date
        var isExpired: Bool { Date() >= expiresAt }
    }

    private var valueCache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private static let cacheTTL: TimeInterval = 5 * 60
    private static let cacheCapacity = 32

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    public static let pattern = #"\{\{kc:([a-zA-Z0-9_-]{1,64})\}\}"#

    /// Phase 2: naive byte-level substitution with no host scoping. Unknown
    /// placeholders are left unchanged. Scoping (`allowed_hosts`) and exfil
    /// detection arrive in Phase 4.
    public func substitute(_ data: Data) async throws -> SubstitutionOutcome {
        // SPECS §7.4: non-UTF-8 bodies are not scanned.
        guard String(data: data, encoding: .utf8) != nil else {
            return SubstitutionOutcome(output: data, substituted: [], unresolved: [], nonUtf8: true)
        }

        let names = Self.findPlaceholderNames(in: data)
        guard !names.isEmpty else {
            return SubstitutionOutcome(output: data, substituted: [], unresolved: [])
        }

        var resolvedValues: [String: Data] = [:]
        var unresolved: [String] = []
        for name in names {
            do {
                let value = try await cachedValue(forName: name)
                resolvedValues[name] = value
            } catch SecretStoreError.unknownSecret {
                unresolved.append(name)
            }
        }

        guard !resolvedValues.isEmpty else {
            return SubstitutionOutcome(output: data, substituted: [], unresolved: unresolved)
        }

        var result = data
        var substituted: [String] = []
        for (name, value) in resolvedValues {
            let needle = Data("{{kc:\(name)}}".utf8)
            let (replaced, hits) = Self.replaceAll(in: result, needle: needle, replacement: value)
            if hits > 0 {
                result = replaced
                substituted.append(name)
            }
        }
        return SubstitutionOutcome(output: result, substituted: substituted, unresolved: unresolved)
    }

    /// Phase 4: host-scoped substitution. Replaces only placeholders whose
    /// `name` appears in `resolvableHits`.
    ///
    /// Substitution is keyed by name (not by `(name, location)`) because
    /// every hit in the request — across all locations — has already passed
    /// the host-mismatch (R1) and non-canonical-location (R2) gates in
    /// `ExfilRuleEngine.evaluate`. Once R1/R2 pass for a name, every
    /// location holding `{{kc:NAME}}` is vetted, so location-aware
    /// substitution would produce the same result at higher cost.
    ///
    /// Non-UTF-8 secret values cannot be spliced into request strings and
    /// are reported via `unresolved` (fail loud, per CLAUDE.md §12).
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

        let authorizedNames = Set(resolvableHits.map(\.name))
        var values: [String: Data] = [:]
        var unresolved: [String] = []
        for name in authorizedNames.sorted() {
            do {
                values[name] = try await cachedValue(forName: name)
            } catch SecretStoreError.unknownSecret {
                unresolved.append(name)
            }
        }

        // SPECS §6: a stored secret whose bytes are not UTF-8 cannot be
        // spliced into header/URI/body strings. Report it as unresolved
        // (fail loud) instead of silently leaving the placeholder literal.
        for (name, data) in values where String(data: data, encoding: .utf8) == nil {
            values.removeValue(forKey: name)
            unresolved.append(name)
        }
        unresolved.sort()

        var substituted = Set<String>()
        func mutate(_ input: String) -> String {
            var result = input
            for name in values.keys.sorted() {
                let needle = "{{kc:\(name)}}"
                guard result.contains(needle) else { continue }
                guard let value = values[name],
                    let valueStr = String(data: value, encoding: .utf8)
                else { continue }
                result = result.replacingOccurrences(of: needle, with: valueStr)
                substituted.insert(name)
            }
            return result
        }

        var newHeaders: [(name: String, value: String)] = []
        newHeaders.reserveCapacity(headers.count)
        for (n, v) in headers {
            newHeaders.append((mutate(n), mutate(v)))
        }
        let newURI = mutate(uri)

        var newBody = body
        if let originalBody = body, let bodyText = String(data: originalBody, encoding: .utf8) {
            let transformed = mutate(bodyText)
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

    // MARK: - Cache

    private func cachedValue(forName name: String) async throws -> Data {
        if let entry = valueCache[name], !entry.isExpired {
            return entry.value
        }
        let value = try await secretStore.value(forName: name)
        insertIntoCache(name: name, value: value)
        return value
    }

    private func insertIntoCache(name: String, value: Data) {
        // Remove existing entry for this name to refresh its position.
        if valueCache[name] != nil {
            cacheOrder.removeAll { $0 == name }
        }
        // Evict until under capacity.
        while valueCache.count >= Self.cacheCapacity {
            if let expiredKey = cacheOrder.first(where: { valueCache[$0]?.isExpired == true }) {
                valueCache.removeValue(forKey: expiredKey)
                cacheOrder.removeAll { $0 == expiredKey }
            } else if let oldest = cacheOrder.first {
                valueCache.removeValue(forKey: oldest)
                cacheOrder.removeFirst()
            } else {
                break
            }
        }
        valueCache[name] = CacheEntry(
            value: value,
            expiresAt: Date().addingTimeInterval(Self.cacheTTL)
        )
        cacheOrder.append(name)
    }

    public func substituteString(_ text: String) async throws -> SubstitutionOutcome {
        try await substitute(Data(text.utf8))
    }

    public static func findPlaceholderNames(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return findPlaceholderNames(in: text)
    }

    public static func findPlaceholderNames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        var order: [String] = []
        for match in matches {
            guard match.numberOfRanges >= 2,
                let captured = Range(match.range(at: 1), in: text)
            else { continue }
            let name = String(text[captured])
            if seen.insert(name).inserted {
                order.append(name)
            }
        }
        return order
    }

    static func replaceAll(
        in haystack: Data,
        needle: Data,
        replacement: Data
    ) -> (Data, Int) {
        guard !needle.isEmpty, !haystack.isEmpty else { return (haystack, 0) }
        var result = Data()
        result.reserveCapacity(haystack.count)
        var hits = 0
        var index = haystack.startIndex
        let end = haystack.endIndex
        while index < end {
            let remaining = end - index
            if remaining >= needle.count {
                let candidate = haystack[index..<(index + needle.count)]
                if candidate.elementsEqual(needle) {
                    result.append(replacement)
                    index += needle.count
                    hits += 1
                    continue
                }
            }
            result.append(haystack[index])
            index += 1
        }
        return (result, hits)
    }
}
