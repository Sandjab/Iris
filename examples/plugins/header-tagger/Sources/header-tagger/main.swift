import Foundation

// header-tagger — IRIS example plugin.
//
// A minimal, safe `onRequest` mutator: it adds an `X-Iris-Plugin: header-tagger`
// header to every matched request. Iris decides WHICH requests are matched (the
// `hooks[].match` block in plugin.json); this process only answers the protocol.
//
// IPC protocol (NDJSON / JSON-RPC 2.0 over stdio — see docs/plugins-design.md §8):
// Iris (the daemon) is the CLIENT: it writes one compact JSON object per line to
// our stdin and we reply with one compact JSON object per line on stdout. Three
// methods arrive over a plugin's lifetime:
//
//   initialize  -> reply {"result":{"ready":true}} once, at startup.
//   on_request  -> reply an `action` per matched request. We always return
//                  `modify` with our tag header. Iris OVERLAYS the returned
//                  headers by name onto the real request, so unspecified headers
//                  (notably the `{{kc:...}}` credential placeholder Iris must
//                  still substitute) are preserved — we never echo them back.
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
    case "shutdown":
        exit(0)
    default:
        break  // unknown method: ignore (forward-compatible)
    }
}
exit(0)
