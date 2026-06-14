import Foundation

/// Endpoint cells (primary / secondary) for an event row. Collapses the CONNECT
/// authority duplication (V3): a CONNECT tunnel carries "host:port" as its `path`,
/// which duplicates the host cell (e.g. "github.com  github.com:443") — show the
/// authority once instead. Normal requests keep host (primary) and path (secondary)
/// distinct.
public func eventEndpoint(method: String, host: String, path: String) -> (primary: String, secondary: String) {
    if method == "CONNECT" {
        return (path.isEmpty ? host : path, "")
    }
    return (host, path)
}
