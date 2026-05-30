import Foundation

/// Human-readable message for an admin RPC error. `JSONRPCError` and `AdminClientError`
/// are both `LocalizedError`; fall back to `localizedDescription` otherwise. Fail loud — never
/// swallow an error into a generic "something went wrong".
func userMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
