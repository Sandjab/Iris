import Foundation

// iris-test-plugin — minimal NDJSON plugin server used ONLY by IRIS P2b
// integration tests. Not shipped (no product entry in Package.swift).
//
// Reads one JSON object per line from stdin, replies on stdout. Mode comes from
// argv[1] (default "ok"):
//   ok               normal: replies ready to initialize, writes an
//                    "initialized" marker into scratch_dir, exits on shutdown.
//   crash            exits non-zero immediately (drives crash-loop tests).
//   ignore-shutdown  replies ready but never exits on shutdown (drives the
//                    SIGTERM/SIGKILL path).

let mode = CommandLine.arguments.dropFirst().first ?? "ok"

if mode == "crash" {
    exit(3)
}

func emitLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    let method = object["method"] as? String
    let id = object["id"] ?? NSNull()

    switch method {
    case "initialize":
        if let params = object["params"] as? [String: Any],
            let scratch = params["scratch_dir"] as? String
        {
            let marker = (scratch as NSString).appendingPathComponent("initialized")
            try? Data("ok".utf8).write(to: URL(fileURLWithPath: marker))
        }
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["ready": true]])
    case "shutdown":
        if mode == "ignore-shutdown" { continue }
        exit(0)
    default:
        break
    }
}
exit(0)
