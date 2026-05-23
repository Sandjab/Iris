import Foundation
import Crypto

public enum Redaction {
    public static func redact(_ value: String) -> String {
        redact(Data(value.utf8))
    }

    public static func redact(_ value: Data) -> String {
        let digest = SHA256.hash(data: value)
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "[REDACTED:\(hex)]"
    }
}
