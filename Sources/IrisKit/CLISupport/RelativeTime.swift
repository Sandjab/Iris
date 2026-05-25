import Foundation

public enum RelativeTimeError: Error, Equatable, LocalizedError {
    case invalidFormat(String)
    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let s): return "Invalid time spec: \(s) (expected Nm|Nh|Nd|Ns or ISO 8601)"
        }
    }
}

/// Parses either a relative duration (`5m`, `2h`, `1d`, `90s`) — returned
/// as a `Date` in the past relative to `now` — or an ISO 8601 timestamp.
public enum RelativeTime {
    public static func parse(_ input: String, relativeTo now: Date) throws -> Date {
        guard !input.isEmpty else { throw RelativeTimeError.invalidFormat(input) }
        if let last = input.last, "smhd".contains(last) {
            let numPart = String(input.dropLast())
            guard let n = Int(numPart), n > 0 else { throw RelativeTimeError.invalidFormat(input) }
            let multiplier: TimeInterval = {
                switch last {
                case "s": return 1
                case "m": return 60
                case "h": return 3_600
                case "d": return 86_400
                default: return 0
                }
            }()
            return now.addingTimeInterval(-Double(n) * multiplier)
        }
        let iso = ISO8601DateFormatter()
        if let parsed = iso.date(from: input) {
            return parsed
        }
        throw RelativeTimeError.invalidFormat(input)
    }
}
