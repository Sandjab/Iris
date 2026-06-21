import Foundation

/// The single capability the dispatcher needs from a plugin process: send one
/// `on_request` and get a typed result, with a per-call timeout. `PluginHost`
/// is the production conformer; tests inject a mock. The dispatcher body is
/// added in a later P3 task.
public protocol PluginInvoking: Sendable {
    var id: String { get }
    func onRequest(_ params: PluginRPC.OnRequestParams, timeout: TimeInterval) async throws
        -> PluginRPC.OnRequestResult
}
