import ArgumentParser
import Foundation
import IrisKit
import Logging

struct IrisDaemonCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "irisd",
        abstract: "IRIS credentials broker daemon (Phase 2 — single-host MITM)."
    )

    @Flag(name: .long, help: "Run in foreground.")
    var foreground: Bool = false

    @Option(name: .long, help: "Listen host (default 127.0.0.1).")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Listen port (default 8888).")
    var port: Int = 8888

    @Option(
        name: .long,
        help: "CA PEM output path (default ~/Library/Application Support/iris/ca.pem)."
    )
    var caPath: String?

    @Option(name: .long, help: "Log level: trace, debug, info, warning, error.")
    var logLevel: String = "info"

    mutating func run() async throws {
        var logger = Logger(label: "io.iris.daemon")
        logger.logLevel = parseLogLevel(logLevel) ?? .info

        let caURL: URL
        if let caPath = caPath {
            caURL = URL(fileURLWithPath: (caPath as NSString).expandingTildeInPath)
        } else {
            let support = ("~/Library/Application Support/iris/ca.pem" as NSString)
                .expandingTildeInPath
            caURL = URL(fileURLWithPath: support)
        }

        // Phase 2: hardcoded single-host whitelist per SPECS-aligned scope.
        let allowedHosts: Set<String> = ["api.anthropic.com"]

        logger.info(
            "Starting irisd",
            metadata: [
                "host": "\(host)",
                "port": "\(port)",
                "allowed_hosts": "\(allowedHosts.sorted())",
            ]
        )

        let daemon = try await Daemon(
            listenHost: host,
            listenPort: port,
            allowedHosts: allowedHosts,
            caPath: caURL,
            logger: logger
        )
        try await daemon.run()
    }

    private func parseLogLevel(_ raw: String) -> Logger.Level? {
        switch raw.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warning
        case "error": return .error
        default: return nil
        }
    }
}

await IrisDaemonCLI.main()
