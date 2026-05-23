import ArgumentParser
import IrisKit

struct IrisCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iris",
        abstract: "IRIS — credentials broker CLI."
    )

    mutating func run() throws {}
}

IrisCLI.main()
