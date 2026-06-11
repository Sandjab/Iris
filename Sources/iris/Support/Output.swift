import Foundation
import IrisKit

enum Output {
    /// JSONEncoder matching the iris CLI output conventions (ISO-8601 dates,
    /// sorted keys, unescaped slashes — snake_case via the explicit
    /// `CodingKeys` on each type). `pretty` adds indentation for one-shot
    /// output; ndjson streams must stay single-line (`pretty: false`).
    static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Print human-readable text, or JSON-encoded `value`, depending on
    /// `json`. `value` must be `Encodable`.
    static func print<E: Encodable>(
        humanText: @autoclosure () -> String,
        jsonValue: E,
        json: Bool
    ) throws {
        if json {
            let data = try makeEncoder().encode(jsonValue)
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
