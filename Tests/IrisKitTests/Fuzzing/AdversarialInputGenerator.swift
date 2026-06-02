import Foundation

/// One synthetic request to feed through the substitution pipeline.
/// `body` is `Data?` so we can exercise non-UTF-8 bodies (the scanner takes
/// `String?` and the proxy passes `nil` for undecodable bytes — we reproduce
/// that contract in the harness).
struct FuzzInput {
    let headers: [(name: String, value: String)]
    let uri: String
    let body: Data?
    let label: String
}

/// Deterministic adversarial corpus targeting the `{{kc:NAME}}` grammar
/// (`[a-zA-Z0-9_-]{1,64}`) and its surroundings. Named cases document intent;
/// the seeded generator adds breadth.
enum AdversarialInputGenerator {
    /// Fixed seed → reproducible corpus. Changing this re-rolls every generated input.
    static let seed: UInt64 = 0xD1CE_5EED_1715_2026

    /// Secret name the pipeline knows about (populated in the harness store).
    static let knownSecretName = "leaky"
    /// Sentinel secret VALUE. Must never appear in any generated input.
    static let sentinel = "SENTINEL_VALUE_DO_NOT_LEAK_7Q3Z"

    private static let canonicalHeader = "x-api-key"
    private static let knownPlaceholder = "{{kc:\(knownSecretName)}}"

    // MARK: - Named regression corpus

    static let namedCorpus: [FuzzInput] = [
        FuzzInput(
            headers: [(canonicalHeader, "Bearer {{kc:\(String(repeating: "a", count: 65))}}")],
            uri: "/v1/messages",
            body: nil,
            label: "name-too-long"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "Bearer {{kc:\(String(repeating: "a", count: 64))}}")],
            uri: "/v1/messages",
            body: nil,
            label: "name-at-limit"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:}}")],
            uri: "/v1/messages",
            body: nil,
            label: "name-empty"
        ),
        FuzzInput(
            headers: [(canonicalHeader, String(repeating: knownPlaceholder, count: 5000))],
            uri: "/v1/messages",
            body: nil,
            label: "thousands-occurrences"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{ {{kc {{kc: kc:x}} }}}} {{")],
            uri: "/v1/messages",
            body: nil,
            label: "unbalanced-braces"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:{{kc:\(knownSecretName)}}}}")],
            uri: "/v1/messages",
            body: nil,
            label: "nested-placeholder"
        ),
        FuzzInput(
            headers: [(canonicalHeader, knownPlaceholder)],
            uri: "/v1/messages",
            body: Data([0xFF, 0xFE, 0x00, 0x80, 0xC0, 0x01]),
            label: "non-utf8-body"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:\u{0000}\u{0001}\u{007F}}}")],
            uri: "/v1/\u{0000}messages",
            body: nil,
            label: "control-chars"
        ),
        FuzzInput(
            headers: [(canonicalHeader, "{{kc:\u{0430}\u{0501}\u{200B}name}}")],
            uri: "/v1/messages",
            body: nil,
            label: "unicode-name"
        ),
        FuzzInput(
            headers: [("X-API-KEY", knownPlaceholder), ("AUTHORIZATION", knownPlaceholder)],
            uri: "/v1/messages",
            body: nil,
            label: "mixed-case-headers"
        ),
    ]

    // MARK: - Seeded generation

    private enum Placement: CaseIterable {
        case canonicalHeader, randomHeader, urlPath, queryString, body
    }

    private static let fragments: [String] = [
        knownPlaceholder,
        "{{kc:}}", "{{kc:" + String(repeating: "z", count: 70) + "}}",
        "{{kc", "kc:}}", "}}{{", "{{kc:{{kc:" + knownSecretName + "}}}}",
        "{{kc:\u{0000}}}", "{{kc:\u{200B}\u{0430}}}", "{{KC:" + knownSecretName + "}}",
        "{{kc:a-b_c}}", "  {{kc:" + knownSecretName + "}}  ",
    ]

    /// Generates `count` adversarial inputs deterministically.
    static func generate(count: Int) -> [FuzzInput] {
        var gen = SeededGenerator(seed: seed)
        var out: [FuzzInput] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let fragment = fragments[Int.random(in: 0..<fragments.count, using: &gen)]
            let repeatCount = Int.random(in: 1...4, using: &gen)
            let payload = String(repeating: fragment, count: repeatCount)
            let placement = Placement.allCases[Int.random(in: 0..<Placement.allCases.count, using: &gen)]
            out.append(make(placement: placement, payload: payload, index: i))
        }
        return out
    }

    private static func make(placement: Placement, payload: String, index: Int) -> FuzzInput {
        switch placement {
        case .canonicalHeader:
            return FuzzInput(
                headers: [(canonicalHeader, payload)],
                uri: "/v1/messages",
                body: nil,
                label: "gen-\(index)-canonical-header"
            )
        case .randomHeader:
            return FuzzInput(
                headers: [("x-custom-\(index % 7)", payload)],
                uri: "/v1/messages",
                body: nil,
                label: "gen-\(index)-random-header"
            )
        case .urlPath:
            return FuzzInput(
                headers: [],
                uri: "/v1/\(payload)/messages",
                body: nil,
                label: "gen-\(index)-url-path"
            )
        case .queryString:
            return FuzzInput(
                headers: [],
                uri: "/v1/messages?token=\(payload)",
                body: nil,
                label: "gen-\(index)-query"
            )
        case .body:
            return FuzzInput(
                headers: [("content-type", "application/json")],
                uri: "/v1/messages",
                body: Data(payload.utf8),
                label: "gen-\(index)-body"
            )
        }
    }
}
