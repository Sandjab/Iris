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
