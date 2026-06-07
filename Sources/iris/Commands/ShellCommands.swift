// Sources/iris/Commands/ShellCommands.swift
import ArgumentParser
import Foundation
import IrisKit

struct ShellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Configure the shell profile (~/.zshrc) to route CLI traffic through IRIS.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Add the IRIS environment block to ~/.zshrc (asks first)."
        )

        @Flag(name: .customLong("yes"), help: "Skip the confirmation prompt.")
        var assumeYes: Bool = false
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            if ShellProfileConfigurator.isInstalled() {
                try Output.ack(message: "already configured", json: json)
                return
            }
            let block = ShellProfileConfigurator.renderBlock()
            if !assumeYes {
                FileHandle.standardError.write(
                    Data(
                        "The following lines will be added to ~/.zshrc:\n\n\(block)\n\nProceed? [y/N] ".utf8
                    )
                )
                let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    try Output.ack(message: "cancelled", json: json)
                    return
                }
            }
            do {
                try ShellProfileConfigurator.install()
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("shell install failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "shell configured — open a new terminal window", json: json)
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove the IRIS environment block from ~/.zshrc."
        )

        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            if !ShellProfileConfigurator.isInstalled() {
                try Output.ack(message: "not configured", json: json)
                return
            }
            do {
                try ShellProfileConfigurator.uninstall()
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("shell uninstall failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "shell block removed", json: json)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report whether the IRIS block is present in ~/.zshrc."
        )

        @Flag(name: .customLong("json")) var json: Bool = false

        struct ShellStatusResult: Encodable { let configured: Bool }

        mutating func run() async throws {
            let configured = ShellProfileConfigurator.isInstalled()
            try Output.print(
                humanText: configured ? "configured" : "not configured",
                jsonValue: ShellStatusResult(configured: configured),
                json: json
            )
            if !configured {
                throw ExitCode(IrisExitCode.logicError)
            }
        }
    }
}
