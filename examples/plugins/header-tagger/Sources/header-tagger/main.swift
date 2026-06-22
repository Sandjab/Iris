import Foundation

// header-tagger — IRIS example plugin.
//
// A minimal, safe `onRequest` mutator: it adds an `X-Iris-Plugin: header-tagger`
// header to every matched request. Iris decides WHICH requests are matched (the
// `hooks[].match` block in plugin.json); this process only answers the protocol.
//
// IPC protocol (NDJSON / JSON-RPC 2.0 over stdio — see docs/plugins-design.md §8):
// Iris (the daemon) is the CLIENT: it writes one compact JSON object per line to
// our stdin and we reply with one compact JSON object per line on stdout. Four
// methods arrive over a plugin's lifetime:
//
//   initialize  -> reply {"result":{"ready":true}} once, at startup.
//   on_request  -> reply an `action` per matched request. We always return
//                  `modify` with our tag header. Iris OVERLAYS the returned
//                  headers by name onto the real request, so unspecified headers
//                  (notably the `{{kc:...}}` credential placeholder Iris must
//                  still substitute) are preserved — we never echo them back.
//   on_complete -> notification (no reply). Appends "METHOD STATUS URI" to
//                  `on_complete.log` in scratch (read-only observability). The
//                  daemon sets our cwd to the sandbox-writable scratch dir so a
//                  relative path resolves correctly.
//   shutdown    -> exit gracefully.
//
// The request we see at `on_request` carries credential PLACEHOLDERS
// (`{{kc:NAME}}`), never resolved secret values: Iris substitutes the real value
// AFTER plugins run (security invariant, design §3). A plugin can never read a
// secret. Accordingly this plugin declares no capabilities.
//
// Foundation-only on purpose: the binary stays self-contained so it runs under
// Iris's deny-by-default sandbox with empty capabilities.

/// Writes one compact JSON object followed by a newline to stdout (NDJSON framing).
func emitLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data)
    try? FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
}

/// Appends one line to `on_complete.log` in the plugin's scratch dir. The daemon
/// sets our cwd to the (sandbox-writable) scratch dir, so a relative path is fine.
func appendCompletionLog(_ line: String) {
    let url = URL(fileURLWithPath: "on_complete.log")  // cwd == scratch dir
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

// One JSON request per line on stdin; reply (or stay silent) per method.
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }  // ignore anything that is not a JSON object
    let id = object["id"] ?? NSNull()  // echo the request id back verbatim

    switch object["method"] as? String {
    case "initialize":
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["ready": true]])
    case "on_request":
        // Always tag. Header removal is not supported; this is a pure overlay.
        emitLine([
            "jsonrpc": "2.0", "id": id,
            "result": ["action": "modify", "headers": [["X-Iris-Plugin", "header-tagger"]]],
        ])
    case "on_complete":
        // Notification: no reply. Record HTTP-level metadata to scratch.
        if let params = object["params"] as? [String: Any] {
            let method = params["method"] as? String ?? "?"
            let status = params["status"] as? Int ?? -1
            let uri = params["uri"] as? String ?? "?"
            appendCompletionLog("\(method) \(status) \(uri)")
        }
    case "shutdown":
        exit(0)
    default:
        break  // unknown method: ignore (forward-compatible)
    }
}
exit(0)
