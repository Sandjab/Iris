import Foundation
import TOMLKit

public enum ConfigLoader {
    public static func load(from url: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.fileReadFailed(path: url.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.fileNotUtf8(path: url.path)
        }
        return try load(toml: text)
    }

    public static func load(toml: String) throws -> Config {
        let decoder = TOMLDecoder()
        let config: Config
        do {
            config = try decoder.decode(Config.self, from: toml)
        } catch let error as ConfigError {
            throw error
        } catch let error as DecodingError {
            throw ConfigError.decodeFailed(message: Self.describe(error))
        } catch {
            throw ConfigError.tomlParseFailed(message: String(describing: error))
        }
        try config.validate()
        return config
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch (expected \(type)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(let type, let ctx):
            return "missing value (expected \(type)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let ctx):
            return
                "data corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
