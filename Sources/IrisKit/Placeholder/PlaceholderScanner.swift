import Foundation

public struct PlaceholderHit: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        case header(name: String)
        case urlPath
        case queryString
        case body
    }
    public let name: String
    public let location: Location
    public let snippet: String

    public init(name: String, location: Location, snippet: String) {
        self.name = name
        self.location = location
        self.snippet = snippet
    }
}

public enum PlaceholderScanner {
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: PlaceholderEngine.pattern)
    }()
    private static let snippetMaxLength = 256
    private static let snippetContextChars = 80

    public static func scan(
        headers: [(name: String, value: String)],
        uri: String,
        body: Data?
    ) -> [PlaceholderHit] {
        var hits: [PlaceholderHit] = []

        for (name, value) in headers {
            let location = PlaceholderHit.Location.header(name: name.lowercased())
            hits.append(contentsOf: scanString(name, location: location))
            hits.append(contentsOf: scanString(value, location: location))
        }

        let (path, query) = splitURI(uri)
        hits.append(contentsOf: scanString(path, location: .urlPath))
        if let query = query {
            hits.append(contentsOf: scanString(query, location: .queryString))
        }

        if let body = body, let bodyText = String(data: body, encoding: .utf8) {
            hits.append(contentsOf: scanString(bodyText, location: .body))
        }

        return hits
    }

    public static func scanString(_ text: String, location: PlaceholderHit.Location) -> [PlaceholderHit] {
        guard let regex = regex else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        return matches.compactMap { match -> PlaceholderHit? in
            guard match.numberOfRanges >= 2,
                let nameRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range(at: 0), in: text)
            else { return nil }
            let name = String(text[nameRange])
            let snippet = makeSnippet(text: text, around: fullRange)
            return PlaceholderHit(name: name, location: location, snippet: snippet)
        }
    }

    private static func splitURI(_ uri: String) -> (path: String, query: String?) {
        guard let qIdx = uri.firstIndex(of: "?") else { return (uri, nil) }
        let path = String(uri[..<qIdx])
        let query = String(uri[uri.index(after: qIdx)...])
        return (path, query)
    }

    private static func makeSnippet(text: String, around range: Range<String.Index>) -> String {
        let startOffset = max(
            text.distance(from: text.startIndex, to: range.lowerBound) - snippetContextChars,
            0
        )
        let endOffset = min(
            text.distance(from: text.startIndex, to: range.upperBound) + snippetContextChars,
            text.count
        )
        let snippetStart = text.index(text.startIndex, offsetBy: startOffset)
        let snippetEnd = text.index(text.startIndex, offsetBy: endOffset)
        let raw = String(text[snippetStart..<snippetEnd])
        let cleaned = raw.map { ch -> Character in
            if ch.isASCII, let scalar = ch.asciiValue, scalar < 0x20 || scalar == 0x7F {
                return "?"
            }
            return ch
        }
        let cleanedString = String(cleaned)
        if cleanedString.count > snippetMaxLength {
            return String(cleanedString.prefix(snippetMaxLength - 1)) + "\u{2026}"
        }
        return cleanedString
    }
}
