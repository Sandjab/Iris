import Foundation

/// Ordered representation of a JSON document — preserves the user's key
/// order in objects, important for hand-edited `.mcp.json` files. RFC 8259
/// strict — rejects comments, trailing commas, duplicate keys, bare empty
/// input.
public struct OrderedJSONDocument: Sendable {
    public private(set) var root: OrderedJSONValue
    public private(set) var commentPositions: [CommentPosition]

    public init(root: OrderedJSONValue, commentPositions: [CommentPosition] = []) {
        self.root = root
        self.commentPositions = commentPositions
    }
}

public struct CommentPosition: Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let kind: Kind
    public enum Kind: Sendable, Equatable { case lineComment, blockComment }

    public init(line: Int, column: Int, kind: Kind) {
        self.line = line
        self.column = column
        self.kind = kind
    }
}

extension OrderedJSONDocument {
    public struct ParseOptions: Sendable {
        public var mode: Mode
        public var recordCommentPositions: Bool

        public enum Mode: Sendable, Equatable { case strict, jsonc }

        public init(mode: Mode, recordCommentPositions: Bool) {
            self.mode = mode
            self.recordCommentPositions = recordCommentPositions
        }

        public static let strict = ParseOptions(mode: .strict, recordCommentPositions: false)
        public static let jsonc = ParseOptions(mode: .jsonc, recordCommentPositions: true)
    }
}

// MARK: - Value type

public indirect enum OrderedJSONValue: Sendable {
    case object([(String, OrderedJSONValue)])
    case array([OrderedJSONValue])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null
}

extension OrderedJSONValue: Equatable {
    public static func == (lhs: OrderedJSONValue, rhs: OrderedJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (la, lb) in zip(a, b) where la.0 != lb.0 || la.1 != lb.1 { return false }
            return true
        default: return false
        }
    }
}

// MARK: - Error type

public enum OrderedJSONError: Error, LocalizedError, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(Character, position: Int)
    case invalidEscape(String, position: Int)
    case invalidNumber(String, position: Int)
    case duplicateKey(String, position: Int)
    case commentNotAllowed(position: Int)
    case trailingCommaNotAllowed(position: Int)
    case unterminatedBlockComment(position: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd:
            return "Unexpected end of input"
        case .unexpectedCharacter(let c, let p):
            return "Unexpected character '\(c)' at position \(p)"
        case .invalidEscape(let s, let p):
            return "Invalid escape \(s) at position \(p)"
        case .invalidNumber(let s, let p):
            return "Invalid number \(s) at position \(p)"
        case .duplicateKey(let k, let p):
            return "Duplicate key '\(k)' at position \(p)"
        case .commentNotAllowed(let p):
            return "Comments not allowed (position \(p)) — JSONC not supported in Phase 5.3"
        case .trailingCommaNotAllowed(let p):
            return "Trailing comma not allowed (position \(p))"
        case .unterminatedBlockComment(let p):
            return "Unterminated /* block comment (position \(p))"
        }
    }
}

// MARK: - Parser

extension OrderedJSONDocument {
    public static func parse(_ input: String) throws -> OrderedJSONDocument {
        try parse(input, options: .strict)
    }

    public static func parse(
        _ input: String,
        options: ParseOptions = .strict
    ) throws -> OrderedJSONDocument {
        var parser = Parser(source: Array(input.unicodeScalars), options: options)
        try parser.skipWhitespaceAndComments()
        guard !parser.isAtEnd else { throw OrderedJSONError.unexpectedEnd }
        let value = try parser.parseValue()
        try parser.skipWhitespaceAndComments()
        if !parser.isAtEnd {
            let c = parser.peek()!
            throw OrderedJSONError.unexpectedCharacter(Character(c), position: parser.position)
        }
        return OrderedJSONDocument(
            root: value,
            commentPositions: parser.recordedComments
        )
    }
}

private struct Parser {
    let source: [Unicode.Scalar]
    let options: OrderedJSONDocument.ParseOptions
    var position: Int = 0
    var recordedComments: [CommentPosition] = []

    init(
        source: [Unicode.Scalar],
        options: OrderedJSONDocument.ParseOptions = .strict
    ) {
        self.source = source
        self.options = options
    }

    var isAtEnd: Bool { position >= source.count }

    func peek() -> Unicode.Scalar? {
        isAtEnd ? nil : source[position]
    }

    @discardableResult
    mutating func advance() -> Unicode.Scalar? {
        guard !isAtEnd else { return nil }
        defer { position += 1 }
        return source[position]
    }

    mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
            position += 1
        }
    }

    mutating func skipWhitespaceAndComments() throws {
        while true {
            skipWhitespace()
            guard options.mode == .jsonc else { return }
            guard let c = peek(), c == "/" else { return }
            guard position + 1 < source.count else { return }
            let next = source[position + 1]
            if next == "/" {
                let (line, column) = lineAndColumn(at: position)
                if options.recordCommentPositions {
                    recordedComments.append(.init(line: line, column: column, kind: .lineComment))
                }
                position += 2
                while let c = peek(), c != "\n" { advance() }
                continue
            }
            if next == "*" {
                let startPos = position
                let (line, column) = lineAndColumn(at: startPos)
                if options.recordCommentPositions {
                    recordedComments.append(.init(line: line, column: column, kind: .blockComment))
                }
                position += 2  // consume "/*"
                var closed = false
                while position + 1 < source.count {
                    if source[position] == "*" && source[position + 1] == "/" {
                        position += 2
                        closed = true
                        break
                    }
                    position += 1
                }
                if !closed {
                    throw OrderedJSONError.unterminatedBlockComment(position: startPos)
                }
                continue
            }
            return  // not a comment start — let caller handle '/' as error
        }
    }

    /// Compute 1-indexed (line, column) for a position offset in `source`.
    /// Lines split on '\n'.
    func lineAndColumn(at offset: Int) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var i = 0
        while i < offset && i < source.count {
            let c = source[i]
            if c == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            i += 1
        }
        return (line, column)
    }

    mutating func parseValue() throws -> OrderedJSONValue {
        try skipWhitespaceAndComments()
        guard let c = peek() else { throw OrderedJSONError.unexpectedEnd }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": return try parseNull()
        case "-", "0"..."9": return try parseNumber()
        case "/":
            throw OrderedJSONError.commentNotAllowed(position: position)
        default:
            throw OrderedJSONError.unexpectedCharacter(Character(c), position: position)
        }
    }

    // MARK: parseObject

    mutating func parseObject() throws -> OrderedJSONValue {
        advance()  // consume '{'
        try skipWhitespaceAndComments()

        var pairs: [(String, OrderedJSONValue)] = []
        var seenKeys = Set<String>()

        guard let first = peek() else { throw OrderedJSONError.unexpectedEnd }
        if first == "}" {
            advance()
            return .object([])
        }

        while true {
            try skipWhitespaceAndComments()
            guard peek() != nil else { throw OrderedJSONError.unexpectedEnd }

            // Parse key
            guard peek() == "\"" else {
                throw OrderedJSONError.unexpectedCharacter(Character(peek()!), position: position)
            }
            let keyPos = position
            let key = try parseString()

            if seenKeys.contains(key) {
                throw OrderedJSONError.duplicateKey(key, position: keyPos)
            }
            seenKeys.insert(key)

            // Colon
            try skipWhitespaceAndComments()
            guard let colon = peek(), colon == ":" else {
                throw OrderedJSONError.unexpectedCharacter(
                    peek().map { Character($0) } ?? "\0",
                    position: position
                )
            }
            advance()

            // Value
            let val = try parseValue()
            pairs.append((key, val))

            try skipWhitespaceAndComments()
            guard let next = peek() else { throw OrderedJSONError.unexpectedEnd }
            if next == "}" {
                advance()
                break
            } else if next == "," {
                advance()
                // Check for trailing comma
                try skipWhitespaceAndComments()
                if let after = peek(), after == "}" {
                    throw OrderedJSONError.trailingCommaNotAllowed(position: position)
                }
            } else {
                throw OrderedJSONError.unexpectedCharacter(Character(next), position: position)
            }
        }

        return .object(pairs)
    }

    // MARK: parseArray

    mutating func parseArray() throws -> OrderedJSONValue {
        advance()  // consume '['
        try skipWhitespaceAndComments()

        var items: [OrderedJSONValue] = []

        guard let first = peek() else { throw OrderedJSONError.unexpectedEnd }
        if first == "]" {
            advance()
            return .array([])
        }

        while true {
            let item = try parseValue()
            items.append(item)

            try skipWhitespaceAndComments()
            guard let next = peek() else { throw OrderedJSONError.unexpectedEnd }
            if next == "]" {
                advance()
                break
            } else if next == "," {
                advance()
                // Check for trailing comma
                try skipWhitespaceAndComments()
                if let after = peek(), after == "]" {
                    throw OrderedJSONError.trailingCommaNotAllowed(position: position)
                }
            } else {
                throw OrderedJSONError.unexpectedCharacter(Character(next), position: position)
            }
        }

        return .array(items)
    }

    // MARK: parseString

    mutating func parseString() throws -> String {
        guard peek() == "\"" else {
            throw OrderedJSONError.unexpectedCharacter(Character(peek() ?? "\0"), position: position)
        }
        advance()  // consume opening '"'

        var result = ""

        while let c = peek() {
            if c == "\"" {
                advance()  // consume closing '"'
                return result
            } else if c == "\\" {
                let escPos = position
                advance()  // consume '\'
                guard let escaped = advance() else {
                    throw OrderedJSONError.unexpectedEnd
                }
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let scalar = try parseUnicodeEscape(at: escPos)
                    result.unicodeScalars.append(scalar)
                default:
                    throw OrderedJSONError.invalidEscape("\\\(Character(escaped))", position: escPos)
                }
            } else if c.value < 0x20 {
                // Unescaped control characters are not allowed in JSON strings
                throw OrderedJSONError.unexpectedCharacter(Character(c), position: position)
            } else {
                result.unicodeScalars.append(c)
                advance()
            }
        }

        throw OrderedJSONError.unexpectedEnd
    }

    // Parse \uXXXX (already consumed \u), handling surrogate pairs.
    mutating func parseUnicodeEscape(at escPos: Int) throws -> Unicode.Scalar {
        let high = try parseHex4(at: escPos)

        // Check if this is a high surrogate (U+D800..U+DBFF)
        if high >= 0xD800 && high <= 0xDBFF {
            // Must be followed by \uDCxx..DFxx low surrogate
            guard position + 1 < source.count,
                source[position] == "\\",
                source[position + 1] == "u"
            else {
                throw OrderedJSONError.invalidEscape("\\u\(String(format: "%04X", high))", position: escPos)
            }
            advance()  // consume '\'
            advance()  // consume 'u'
            let low = try parseHex4(at: escPos)
            guard low >= 0xDC00 && low <= 0xDFFF else {
                throw OrderedJSONError.invalidEscape(
                    "\\u\(String(format: "%04X", high))\\u\(String(format: "%04X", low))",
                    position: escPos
                )
            }
            // Combine surrogate pair into a scalar
            let codePoint = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(codePoint) else {
                throw OrderedJSONError.invalidEscape(
                    "surrogate pair U+\(String(format: "%06X", codePoint))",
                    position: escPos
                )
            }
            return scalar
        }

        // Lone low surrogate is invalid
        if high >= 0xDC00 && high <= 0xDFFF {
            throw OrderedJSONError.invalidEscape("\\u\(String(format: "%04X", high))", position: escPos)
        }

        guard let scalar = Unicode.Scalar(high) else {
            throw OrderedJSONError.invalidEscape("\\u\(String(format: "%04X", high))", position: escPos)
        }
        return scalar
    }

    // Parse exactly 4 hex digits and return their value.
    mutating func parseHex4(at escPos: Int) throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let c = advance() else { throw OrderedJSONError.unexpectedEnd }
            guard let digit = hexDigit(c) else {
                throw OrderedJSONError.invalidEscape("\\u (non-hex digit '\(Character(c))')", position: escPos)
            }
            value = value * 16 + digit
        }
        return value
    }

    func hexDigit(_ c: Unicode.Scalar) -> UInt32? {
        switch c {
        case "0"..."9": return c.value - Unicode.Scalar("0").value
        case "a"..."f": return c.value - Unicode.Scalar("a").value + 10
        case "A"..."F": return c.value - Unicode.Scalar("A").value + 10
        default: return nil
        }
    }

    // MARK: parseBool

    mutating func parseBool() throws -> Bool {
        let pos = position
        if source.count - position >= 4
            && source[position] == "t"
            && source[position + 1] == "r"
            && source[position + 2] == "u"
            && source[position + 3] == "e"
        {
            position += 4
            return true
        }
        if source.count - position >= 5
            && source[position] == "f"
            && source[position + 1] == "a"
            && source[position + 2] == "l"
            && source[position + 3] == "s"
            && source[position + 4] == "e"
        {
            position += 5
            return false
        }
        throw OrderedJSONError.unexpectedCharacter(Character(source[pos]), position: pos)
    }

    // MARK: parseNull

    mutating func parseNull() throws -> OrderedJSONValue {
        let pos = position
        guard
            source.count - position >= 4
                && source[position] == "n"
                && source[position + 1] == "u"
                && source[position + 2] == "l"
                && source[position + 3] == "l"
        else {
            throw OrderedJSONError.unexpectedCharacter(Character(source[pos]), position: pos)
        }
        position += 4
        return .null
    }

    // MARK: parseNumber

    mutating func parseNumber() throws -> OrderedJSONValue {
        let startPos = position
        var numStr = ""
        var isFloat = false

        // Optional leading minus
        if peek() == "-" {
            numStr.append("-")
            advance()
        }

        guard let first = peek() else {
            throw OrderedJSONError.invalidNumber(numStr, position: startPos)
        }

        // Integer part
        if first == "0" {
            numStr.append("0")
            advance()
            // Leading zero: next must NOT be a digit (reject 01, 007, etc.)
            if let next = peek(), next >= "0" && next <= "9" {
                throw OrderedJSONError.invalidNumber(numStr + String(Character(next)), position: startPos)
            }
        } else if first >= "1" && first <= "9" {
            while let c = peek(), c >= "0" && c <= "9" {
                numStr.unicodeScalars.append(c)
                advance()
            }
        } else {
            throw OrderedJSONError.invalidNumber(numStr, position: startPos)
        }

        // Optional fractional part
        if peek() == "." {
            isFloat = true
            numStr.append(".")
            advance()
            guard let fd = peek(), fd >= "0" && fd <= "9" else {
                throw OrderedJSONError.invalidNumber(numStr, position: startPos)
            }
            while let c = peek(), c >= "0" && c <= "9" {
                numStr.unicodeScalars.append(c)
                advance()
            }
        }

        // Optional exponent
        if let e = peek(), e == "e" || e == "E" {
            isFloat = true
            numStr.unicodeScalars.append(e)
            advance()
            if let sign = peek(), sign == "+" || sign == "-" {
                numStr.unicodeScalars.append(sign)
                advance()
            }
            guard let ed = peek(), ed >= "0" && ed <= "9" else {
                throw OrderedJSONError.invalidNumber(numStr, position: startPos)
            }
            while let c = peek(), c >= "0" && c <= "9" {
                numStr.unicodeScalars.append(c)
                advance()
            }
        }

        if isFloat {
            guard let d = Double(numStr) else {
                throw OrderedJSONError.invalidNumber(numStr, position: startPos)
            }
            return .double(d)
        } else {
            // Try Int64 first; fall back to Double on overflow
            if let i = Int64(numStr) {
                return .integer(i)
            } else if let d = Double(numStr) {
                return .double(d)
            } else {
                throw OrderedJSONError.invalidNumber(numStr, position: startPos)
            }
        }
    }
}

// MARK: - Serializer

extension OrderedJSONDocument {
    public static func serialize(_ document: OrderedJSONDocument) -> String {
        var out = ""
        emit(document.root, indent: 0, into: &out)
        out.append("\n")
        return out
    }

    // swiftlint:disable function_body_length
    private static func emit(_ value: OrderedJSONValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let padPlus = String(repeating: "  ", count: indent + 1)
        switch value {
        case .null:
            out.append("null")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .integer(let n):
            out.append(String(n))
        case .double(let d):
            // Preserve fractional form even for whole values like 1.0
            if d == d.rounded() && abs(d) < 1e15 && !d.isInfinite && !d.isNaN {
                out.append(String(format: "%.1f", d))
            } else {
                out.append(String(d))
            }
        case .string(let s):
            out.append("\"")
            out.append(escapeString(s))
            out.append("\"")
        case .array(let items):
            if items.isEmpty {
                out.append("[]")
            } else {
                out.append("[\n")
                for (i, item) in items.enumerated() {
                    out.append(padPlus)
                    emit(item, indent: indent + 1, into: &out)
                    if i < items.count - 1 { out.append(",") }
                    out.append("\n")
                }
                out.append(pad)
                out.append("]")
            }
        case .object(let pairs):
            if pairs.isEmpty {
                out.append("{}")
            } else {
                out.append("{\n")
                for (i, (key, val)) in pairs.enumerated() {
                    out.append(padPlus)
                    out.append("\"")
                    out.append(escapeString(key))
                    out.append("\": ")
                    emit(val, indent: indent + 1, into: &out)
                    if i < pairs.count - 1 { out.append(",") }
                    out.append("\n")
                }
                out.append(pad)
                out.append("}")
            }
        }
    }

    private static func escapeString(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

// MARK: - Mutation API

extension OrderedJSONDocument {
    /// Sets the value at the given path of object keys, creating intermediate
    /// objects as needed. Preserves order of existing keys. Throws if any
    /// intermediate key references a non-object.
    public mutating func setValue(_ value: OrderedJSONValue, atPath path: [String]) throws {
        guard !path.isEmpty else { throw OrderedJSONError.unexpectedEnd }
        root = try Self.setValueInNode(value, atPath: path, in: root)
    }

    private static func setValueInNode(
        _ value: OrderedJSONValue,
        atPath path: [String],
        in node: OrderedJSONValue
    ) throws -> OrderedJSONValue {
        guard case .object(var pairs) = node else {
            throw OrderedJSONError.unexpectedCharacter("?", position: 0)
        }
        let key = path[0]
        if path.count == 1 {
            if let idx = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[idx] = (key, value)
            } else {
                pairs.append((key, value))
            }
        } else {
            let rest = Array(path.dropFirst())
            if let idx = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[idx] = (key, try setValueInNode(value, atPath: rest, in: pairs[idx].1))
            } else {
                // Create intermediate empty object
                let nested = try setValueInNode(value, atPath: rest, in: .object([]))
                pairs.append((key, nested))
            }
        }
        return .object(pairs)
    }
}
