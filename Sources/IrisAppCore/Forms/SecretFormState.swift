import Foundation
import IrisKit

/// Pure validation state for the secret Add / Edit / Rotate forms. UI binds to this;
/// all validation lives here (testable headless). Mirrors the daemon-side rules so the
/// app never sends an RPC that the daemon will reject.
@MainActor
public final class SecretFormState: ObservableObject {
    public enum Mode: Equatable {
        case add
        case edit(existing: Secret)  // name + value locked, hosts editable
        case rotate(existing: Secret)  // value only
    }

    public let mode: Mode
    @Published public var name: String = ""
    @Published public var value: String = ""
    @Published public var hostsInput: String = ""

    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add:
            break
        case .edit(let s):
            name = s.name
            hostsInput = s.allowedHosts.joined(separator: ", ")
        case .rotate(let s):
            name = s.name
        }
    }

    /// Parsed, trimmed, de-duplicated host tokens (insertion order preserved).
    public var hosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in hostsInput.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            let h = raw.trimmingCharacters(in: .whitespaces)
            if !h.isEmpty, seen.insert(h).inserted {
                out.append(h)
            }
        }
        return out
    }

    /// Raw secret bytes for the RPC (binary-safe; never logged or re-read).
    public var valueData: Data {
        Data(value.utf8)
    }

    public var validationError: String? {
        switch mode {
        case .add:
            if !nameIsValid {
                return "Name must match [a-zA-Z0-9_-], 1–64 chars."
            }
            if value.isEmpty {
                return "Value is required."
            }
            return hostsError
        case .edit:
            return hostsError
        case .rotate:
            return value.isEmpty ? "Value is required." : nil
        }
    }

    public var canSubmit: Bool {
        validationError == nil
    }

    private var nameIsValid: Bool {
        do {
            try Secret.validateName(name)
            return true
        } catch {
            return false
        }
    }

    private var hostsError: String? {
        let parsed = hosts
        if parsed.isEmpty {
            return "At least one allowed host is required."
        }
        if let bad = parsed.first(where: { !Secret.isValidHost($0) }) {
            return "Invalid host: \(bad)"
        }
        return nil
    }
}
