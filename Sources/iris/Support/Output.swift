import Foundation
import IrisKit

enum Output {
    /// Print human-readable text, or JSON-encoded `value`, depending on
    /// `json`. `value` must be `Encodable` and is encoded with sorted keys +
    /// pretty-printing (cohérent avec wire format Phase 3 : snake_case via
    /// les `CodingKeys` explicites sur chaque type).
    static func print<E: Encodable>(
        humanText: @autoclosure () -> String,
        jsonValue: E,
        json: Bool
    ) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(jsonValue)
            if let text = String(data: data, encoding: .utf8) {
                Swift.print(text)
            }
        } else {
            Swift.print(humanText())
        }
    }

    /// Convenience for commands that don't produce a structured payload
    /// in `--json` mode (acks, no-ops). Emits `{"ok": true, "message": "..."}`
    /// when `json == true`.
    static func ack(message: String, json: Bool) throws {
        struct Ack: Encodable {
            let ok: Bool
            let message: String
        }
        try print(humanText: message, jsonValue: Ack(ok: true, message: message), json: json)
    }
}
