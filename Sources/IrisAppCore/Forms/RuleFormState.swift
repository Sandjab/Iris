import Foundation
import IrisKit

/// Pure validation state for the Rules "Add host" field. Client-side feedback only;
/// the daemon (`rule.add`) remains the authority and may still reject (see spec §4).
@MainActor
public final class RuleFormState: ObservableObject {
    @Published public var host: String = ""

    public init() {}

    public var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    public var validationError: String? {
        let h = trimmedHost
        if h.isEmpty {
            return "Host is required."
        }
        if !Secret.isValidHost(h) {
            return "Invalid host (DNS-like, ≤253 chars)."
        }
        return nil
    }

    public var canSubmit: Bool {
        validationError == nil
    }
}
