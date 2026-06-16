import Foundation
import Security

public struct CACertificate: Sendable, Hashable {
    public let derBytes: Data
    public let pem: String
    public let fingerprintSHA256: String
    public let notBefore: Date
    public let notAfter: Date
    public let commonName: String

    public init(
        derBytes: Data,
        pem: String,
        fingerprintSHA256: String,
        notBefore: Date,
        notAfter: Date,
        commonName: String
    ) {
        self.derBytes = derBytes
        self.pem = pem
        self.fingerprintSHA256 = fingerprintSHA256
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.commonName = commonName
    }
}

public enum CAError: Error, LocalizedError, Equatable {
    case certificateBuildFailed(message: String)
    case certificateSerializationFailed(message: String)
    case pemWriteFailed(path: String)
    case directoryCreationFailed(path: String)
    case keychainStatus(OSStatus)
    case dataCorruption(String)
    case trustCommandFailed(status: Int32, message: String)
    case duplicateCAKey

    public var errorDescription: String? {
        switch self {
        case .certificateBuildFailed(let message):
            return "Failed to build CA certificate: \(message)"
        case .certificateSerializationFailed(let message):
            return "Failed to serialize CA certificate: \(message)"
        case .pemWriteFailed(let path):
            return "Could not write CA PEM to \(path)"
        case .directoryCreationFailed(let path):
            return "Could not create directory \(path)"
        case .keychainStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error: \(message ?? "OSStatus \(status)")"
        case .dataCorruption(let reason):
            return "CA data corruption: \(reason)"
        case .trustCommandFailed(let status, let message):
            return "security tool failed (exit \(status)): \(message)"
        case .duplicateCAKey:
            return
                "A CA private key item already exists; refusing to overwrite or adopt it"
        }
    }
}
