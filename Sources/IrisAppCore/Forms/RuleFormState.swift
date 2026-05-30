import Foundation
import IrisKit

/// Pure validation state for the Rules "Add host" field. Client-side feedback only;
/// the daemon (`rule.add`) remains the authority and may still reject (see spec §4).
///
/// `canSubmit` gates the Add button; `displayError` surfaces a message ONLY once the user has
/// typed a non-empty but malformed host, so an empty field shows no premature error.
@MainActor
public final class RuleFormState: ObservableObject {
    @Published public var host: String = ""

    public init() {}

    public var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    public var canSubmit: Bool {
        let h = trimmedHost
        return !h.isEmpty && Secret.isValidHost(h)
    }

    /// Message shown only when the user typed a non-empty but malformed host.
    public var displayError: String? {
        let h = trimmedHost
        if !h.isEmpty, !Secret.isValidHost(h) {
            return "Invalid host (DNS-like, ≤253 chars)."
        }
        return nil
    }
}
