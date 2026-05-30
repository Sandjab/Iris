import Foundation
import IrisKit

/// Pure validation state for the secret Add / Edit / Rotate forms. UI binds to this;
/// all validation lives here (testable headless). Mirrors the daemon-side rules so the
/// app never sends an RPC that the daemon will reject.
///
/// Validation is split into three concerns so a pristine form is not littered with errors:
/// - `canSubmit` gates the submit button (all required fields valid).
/// - `displayError` surfaces a message ONLY for input the user typed that is malformed.
/// - `incompleteHint` is a neutral "what's still missing" hint when nothing is malformed.
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

    /// Whether the form can be submitted (all required fields valid). Drives the submit button.
    public var canSubmit: Bool {
        switch mode {
        case .add:
            return nameIsValid && !value.isEmpty && hostsSubmittable
        case .edit:
            return hostsSubmittable
        case .rotate:
            return !value.isEmpty
        }
    }

    /// A message shown ONLY for input the user typed that is malformed (a bad name, a bad host).
    /// Empty/required fields produce no message here — the disabled button plus `incompleteHint`
    /// communicate that — so a pristine form is not covered in red text.
    public var displayError: String? {
        switch mode {
        case .add:
            if !name.isEmpty, !nameIsValid {
                return "Name must match [a-zA-Z0-9_-], 1–64 chars."
            }
            return malformedHostError
        case .edit:
            return malformedHostError
        case .rotate:
            return nil
        }
    }

    /// A neutral hint shown when the form is incomplete but nothing is malformed, so the user
    /// knows what is still required without an alarming error.
    public var incompleteHint: String? {
        guard !canSubmit, displayError == nil else { return nil }
        switch mode {
        case .add:
            return "Enter a name, a value, and at least one allowed host."
        case .edit:
            return "Enter at least one allowed host."
        case .rotate:
            return "Enter a new value."
        }
    }

    private var nameIsValid: Bool {
        do {
            try Secret.validateName(name)
            return true
        } catch {
            return false
        }
    }

    /// The first non-empty host token that is malformed, as an error message; nil when no host
    /// has been typed or all are valid.
    private var malformedHostError: String? {
        if let bad = hosts.first(where: { !Secret.isValidHost($0) }) {
            return "Invalid host: \(bad)"
        }
        return nil
    }

    /// At least one host entered and every entered host valid (matches the daemon's rule).
    private var hostsSubmittable: Bool {
        let parsed = hosts
        return !parsed.isEmpty && parsed.allSatisfy { Secret.isValidHost($0) }
    }
}
