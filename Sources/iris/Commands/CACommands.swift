import ArgumentParser
import Foundation
import IrisKit

struct CACommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ca",
        abstract: "Manage the IRIS root CA.",
        subcommands: [Export.self, Fingerprint.self, IsTrusted.self]
    )

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Print the CA file path, copy it elsewhere, or print the PEM."
        )

        @OptionGroup var connection: ConnectionOptions
        @Option(name: .customLong("path"), help: "Copy the CA cert to this path instead of printing the source path.")
        var destination: String?
        @Flag(name: .customLong("print"), help: "Print the PEM contents on stdout.")
        var printPem: Bool = false
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(.caExportPath, returning: CAExportPathResult.self)
            }
            if let destination = destination {
                let expanded = (destination as NSString).expandingTildeInPath
                do {
                    if FileManager.default.fileExists(atPath: expanded) {
                        try FileManager.default.removeItem(atPath: expanded)
                    }
                    try FileManager.default.copyItem(atPath: result.path, toPath: expanded)
                } catch {
                    FileHandle.standardError.write(Data("copy failed: \(error)\n".utf8))
                    throw ExitCode(IrisExitCode.ioError)
                }
                try Output.ack(message: "copied CA to \(expanded)", json: json)
                return
            }
            if printPem {
                let pem = try String(contentsOfFile: result.path, encoding: .utf8)
                print(pem, terminator: "")
                return
            }
            try Output.print(humanText: result.path, jsonValue: result, json: json)
        }
    }

    struct Fingerprint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fingerprint",
            abstract: "Print the CA SHA-256 fingerprint."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(.caFingerprint, returning: CAFingerprintResult.self)
            }
            try Output.print(humanText: "sha256: \(result.sha256)", jsonValue: result, json: json)
        }
    }

    struct IsTrusted: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "is-trusted",
            abstract: "Check whether the CA is in the user trust store."
        )

        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(.caIsTrusted, returning: CAIsTrustedResult.self)
            }
            try Output.print(
                humanText: result.trusted ? "trusted" : "not trusted",
                jsonValue: result,
                json: json
            )
            if !result.trusted {
                throw ExitCode(IrisExitCode.logicError)
            }
        }
    }
}
