import Foundation
import Logging

/// Owns plugin discovery and lifecycle *state* (P1: no running process).
/// Merges manifests discovered under `pluginsDirectory/<id>/plugin.json` with
/// the persisted `PluginStateEntry` array in `config.json`. The state array is
/// the source of truth for the installed set.
public actor PluginRegistry {
    private let pluginsDirectory: URL
    private let configStore: ConfigStore
    private let logger: Logger
    private let fm = FileManager.default

    public init(pluginsDirectory: URL, configStore: ConfigStore, logger: Logger) {
        self.pluginsDirectory = pluginsDirectory
        self.configStore = configStore
        self.logger = logger
    }

    // MARK: - Private helpers

    private func directory(for id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func loadManifest(id: String) throws -> PluginManifest {
        let url = directory(for: id).appendingPathComponent("plugin.json")
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw PluginError.ioError("read manifest \(id): \(error)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PluginManifest
        do { manifest = try decoder.decode(PluginManifest.self, from: data) } catch {
            throw PluginError.invalidManifest("\(id): \(error)")
        }
        try manifest.validate()
        return manifest
    }

    private func view(for entry: PluginStateEntry) throws -> Plugin {
        let manifest = try loadManifest(id: entry.id)
        let currentHash = try PluginHasher.hash(directory: directory(for: entry.id))
        return Plugin(
            manifest: manifest,
            enabled: entry.enabled,
            order: entry.order,
            approvedCapabilities: entry.approvedCapabilities,
            pinnedHash: entry.pinnedHash,
            hashMatches: currentHash == entry.pinnedHash
        )
    }

    // MARK: - Public API

    /// All installed plugins, sorted by chain order. A state entry whose
    /// manifest no longer loads is logged and skipped (it stays installed in
    /// config; a later phase can surface it as broken).
    public func list() async throws -> [Plugin] {
        let entries = await configStore.plugins()
        var out: [Plugin] = []
        for entry in entries.sorted(by: { $0.order < $1.order }) {
            do { out.append(try view(for: entry)) } catch {
                logger.warning(
                    "plugin skipped",
                    metadata: ["id": "\(entry.id)", "error": "\(error)"]
                )
            }
        }
        return out
    }

    public func info(id: String) async throws -> Plugin {
        let entries = await configStore.plugins()
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        return try view(for: entry)
    }

    /// Validates the source manifest, copies the directory into the per-user
    /// plugins dir, pins a content hash, and records a *disabled* state entry.
    public func install(from sourceDir: URL) async throws -> Plugin {
        let manifestURL = sourceDir.appendingPathComponent("plugin.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch {
            throw PluginError.ioError("read source manifest: \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PluginManifest
        do { manifest = try decoder.decode(PluginManifest.self, from: data) } catch {
            throw PluginError.invalidManifest("\(error)")
        }
        try manifest.validate()

        var entries = await configStore.plugins()
        guard !entries.contains(where: { $0.id == manifest.id }) else {
            throw PluginError.duplicateId(manifest.id)
        }

        let hash = try PluginHasher.hash(directory: sourceDir)
        let dest = directory(for: manifest.id)
        do {
            try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: sourceDir, to: dest)
        } catch {
            throw PluginError.ioError("copy plugin \(manifest.id): \(error)")
        }

        let nextOrder = (entries.map(\.order).max() ?? -1) + 1
        let newEntry = PluginStateEntry(
            id: manifest.id,
            enabled: false,
            order: nextOrder,
            approvedCapabilities: nil,
            pinnedHash: hash,
            configValues: [:]
        )
        entries.append(newEntry)
        do { try await configStore.setPlugins(entries) } catch {
            try? fm.removeItem(at: dest)  // roll back the copy on persist failure
            throw error
        }
        return try view(for: newEntry)
    }
}
