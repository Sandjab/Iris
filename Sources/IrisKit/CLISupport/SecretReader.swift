import Foundation

public enum SecretReaderError: Error, Equatable, LocalizedError {
    case emptyValue

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            return "Secret value cannot be empty or whitespace-only"
        }
    }
}

/// Pure secret-value normalization. Strips at most one trailing `\n`
/// (LF) to make stdin pipes ergonomic without surprising callers that
/// pass binary data. Refuses whitespace-only inputs to catch obvious
/// mistakes (heredoc with empty line, accidental Enter at prompt).
public enum SecretReader {
    public static func read(from data: Data) throws -> Data {
        var trimmed = data
        if trimmed.last == 0x0A {
            trimmed = trimmed.dropLast()
        }
        let isWhitespaceOnly: Bool = {
            guard let text = String(data: trimmed, encoding: .utf8) else { return false }
            return text.allSatisfy(\.isWhitespace)
        }()
        if trimmed.isEmpty || isWhitespaceOnly {
            throw SecretReaderError.emptyValue
        }
        return trimmed
    }
}
