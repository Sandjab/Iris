import Foundation
import Logging

/// Persists CLI-added MITM rules to a JSON file beside the admin socket.
///
/// Thread-safe via Swift actor isolation. All mutations are written atomically
/// to disk with 0600 permissions. JSON parse errors on load are silently ignored
/// (logged at warning) so a corrupted file doesn't block daemon boot — the next
/// write will overwrite. I/O errors (e.g. permission denied) still propagate
/// out of `init` as `Error.ioError`.
public actor RuntimeRulesStore {
    // MARK: - Error

    public enum Error: Swift.Error, Equatable {
        case invalidHost(String)
        case ioError(String)
    }

    // MARK: - State

    private let path: URL
    private let logger: Logger
    /// Keyed by host for O(1) dedup. Output is always sorted by host.
    private var rules: [String: MITMRule]

    // MARK: - Init

    public init(path: URL, logger: Logger) async throws {
        self.path = path
        self.logger = logger
        // Load persisted state inline — actor isolation begins after all stored
        // properties are initialized, so calling `self.load()` here triggers a
        // Swift 5.9 strict-concurrency warning. Instead we inline the load logic.
        self.rules = try Self.loadRules(from: path, logger: logger)
    }

    // MARK: - Read

    public func list() -> [MITMRule] {
        rules.values.sorted { $0.host < $1.host }
    }

    public func contains(host: String) -> Bool {
        rules[host] != nil
    }

    // MARK: - Write

    @discardableResult
    public func add(host: String, now: Date) throws -> MITMRule {
        try Self.validateHost(host)
        if let existing = rules[host] {
            return existing
        }
        let rule = MITMRule(host: host, createdAt: now, source: .runtime)
        rules[host] = rule
        try persist()
        return rule
    }

    public func delete(host: String) throws -> Bool {
        guard rules.removeValue(forKey: host) != nil else { return false }
        try persist()
        return true
    }

    // MARK: - Persistence

    /// Static helper so init can call it without crossing actor isolation boundary.
    private static func loadRules(from path: URL, logger: Logger) throws -> [String: MITMRule] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw Error.ioError("read failed: \(error)")
        }
        guard !data.isEmpty else { return [:] }

        do {
            let decoder = JSONRPCCoder.makeDecoder()
            let decoded = try decoder.decode([MITMRule].self, from: data)
            var result: [String: MITMRule] = [:]
            for rule in decoded {
                // Normalize source to .runtime defensively: this file only persists
                // runtime-added rules, but a tampered/corrupted file could claim .toml.
                // Reject that ambiguity at load time by forcing the source.
                result[rule.host] = MITMRule(host: rule.host, createdAt: rule.createdAt, source: .runtime)
            }
            return result
        } catch {
            // Corrupted file must not block daemon boot — warn and start empty.
            // Next persist() will overwrite with clean state.
            logger.warning(
                "runtime-rules.json parse failed — ignoring file",
                metadata: ["error": "\(error)"]
            )
            return [:]
        }
    }

    private func persist() throws {
        // Fresh encoder: persistence format genuinely differs from the wire format
        // produced by JSONRPCCoder (we want prettyPrinted for human-editable file,
        // and don't care about .withoutEscapingSlashes here).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let snapshot = rules.values.sorted { $0.host < $1.host }
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw Error.ioError("encode failed: \(error)")
        }

        let tmpPath = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpPath, options: [.atomic])
            // Enforce 0600 — write(to:options:) inherits umask (usually 0644).
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: tmpPath.path
            )
            // Atomic replace preserves the 0600 permissions set on the tmp file.
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
        } catch {
            // System calls above throw NSError/POSIXError, never RuntimeRulesStore.Error,
            // so a single catch suffices.
            try? FileManager.default.removeItem(at: tmpPath)
            throw Error.ioError("write failed: \(error)")
        }
    }

    // MARK: - Validation

    /// Accepts hostnames: lowercase alphanumeric, hyphens, dots. No leading/trailing
    /// dots or hyphens. Max 253 characters. Rejects empty, paths, or strings with spaces.
    private static let hostPattern = #"^[a-z0-9](?:[a-z0-9.\-]*[a-z0-9])?$"#
    // Safe: literal regex that is always valid. Failure is a programmer error, not runtime.
    private static let hostRegex = try! NSRegularExpression(pattern: hostPattern)  // swiftlint:disable:this force_try

    private static func validateHost(_ host: String) throws {
        let range = NSRange(host.startIndex..., in: host)
        guard
            !host.isEmpty,
            host.count <= 253,
            hostRegex.firstMatch(in: host, range: range) != nil
        else {
            throw Error.invalidHost(host)
        }
    }
}
