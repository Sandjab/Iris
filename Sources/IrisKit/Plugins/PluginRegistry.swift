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
    private let sourceLimits: PluginSourceValidator.Limits

    /// Memoised content hash per plugin id, keyed on a cheap stat-only signature.
    /// `view`/`enable` re-hash on every `list`/`info`; the cache returns the pinned
    /// digest unchanged unless the tree's signature moved (#9). Actor-isolated, so
    /// no locking. Invalidated on `remove`.
    private struct CachedHash {
        let signature: String
        let value: String
    }
    private var hashCache: [String: CachedHash] = [:]

    /// Content hash for `id`, reusing the cache when the stat-only signature is
    /// unchanged (#9). A moved signature forces a recompute — so a tamper is never
    /// masked by a stale cache entry.
    private func currentHash(id: String, directory: URL) throws -> String {
        let signature = try PluginHasher.signature(directory: directory)
        if let cached = hashCache[id], cached.signature == signature {
            return cached.value
        }
        let value = try PluginHasher.hash(directory: directory)
        hashCache[id] = CachedHash(signature: signature, value: value)
        return value
    }

    public init(
        pluginsDirectory: URL,
        configStore: ConfigStore,
        logger: Logger,
        sourceLimits: PluginSourceValidator.Limits = PluginSourceValidator.Limits()
    ) {
        self.pluginsDirectory = pluginsDirectory
        self.configStore = configStore
        self.logger = logger
        self.sourceLimits = sourceLimits
    }

    // MARK: - Private helpers

    /// Single point where a filesystem path is derived from a plugin id. Validates
    /// the id as a safe, non-traversing path component (#7) — every other method
    /// that touches a per-plugin directory routes through here, so an unsafe id can
    /// never reach `FileManager` (nor leak a derived path through an ioError
    /// message). Installed ids were already validated at install (manifest.validate);
    /// this only throws for an id injected directly (e.g. a hand-edited config), and
    /// public callers reject an unknown id as `unknownPlugin` before reaching here.
    private func directory(for id: String) throws -> URL {
        guard PluginManifest.isSafePathComponent(id) else {
            throw PluginError.invalidManifest("invalid id: \(id)")
        }
        return pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func loadManifest(id: String) throws -> PluginManifest {
        let url = try directory(for: id).appendingPathComponent("plugin.json")
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
        let currentHash = try currentHash(id: entry.id, directory: directory(for: entry.id))
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

        // Refuse a source tree with symlinks (unpinned by the hasher) or one that
        // blows the size/count caps, BEFORE copying anything (#8).
        try PluginSourceValidator.validate(directory: sourceDir, limits: sourceLimits)

        // cheap early reject (optimization only; the atomic block below is authoritative)
        if await configStore.plugins().contains(where: { $0.id == manifest.id }) {
            throw PluginError.duplicateId(manifest.id)
        }
        let hash = try PluginHasher.hash(directory: sourceDir)
        let dest = try directory(for: manifest.id)
        do {
            try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                logger.warning(
                    "install: removing pre-existing plugin directory with no state entry",
                    metadata: ["id": "\(manifest.id)"]
                )
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourceDir, to: dest)
        } catch {
            try? fm.removeItem(at: dest)  // clean a partial copy
            throw PluginError.ioError("copy plugin \(manifest.id): \(error)")
        }
        let entries: [PluginStateEntry]
        do {
            entries = try await configStore.updatePlugins { current in
                guard !current.contains(where: { $0.id == manifest.id }) else {
                    throw PluginError.duplicateId(manifest.id)
                }
                let order = (current.map(\.order).max() ?? -1) + 1
                return current + [
                    PluginStateEntry(
                        id: manifest.id,
                        enabled: false,
                        order: order,
                        approvedCapabilities: nil,
                        pinnedHash: hash,
                        configValues: [:]
                    )
                ]
            }
        } catch {
            try? fm.removeItem(at: dest)  // roll back the copy on persist/dup failure
            throw error
        }
        guard let newEntry = entries.first(where: { $0.id == manifest.id }) else {
            throw PluginError.ioError("install: entry missing after persist for \(manifest.id)")
        }
        // hashMatches is true by construction (we just hashed + pinned the same dir) —
        // build the view directly, do NOT re-hash via view(for:) (avoids redundant I/O
        // and a misleading post-persist failure).
        return Plugin(
            manifest: manifest,
            enabled: newEntry.enabled,
            order: newEntry.order,
            approvedCapabilities: newEntry.approvedCapabilities,
            pinnedHash: newEntry.pinnedHash,
            hashMatches: true
        )
    }

    // MARK: - Mutations

    /// Approves the manifest's declared capabilities and flips `enabled` on.
    /// Refuses if the on-disk content drifted from the pinned hash (TOFU).
    public func enable(id: String) async throws -> Plugin {
        // Reject an id that isn't installed up front — uniform with info/disable,
        // and a clean `unknownPlugin` instead of a filesystem error that leaks the
        // plugins-directory path. Since every installed id was validated as a safe
        // path component at install time, this also keeps loadManifest/hash off any
        // path derived from an untrusted or non-existent id. The authoritative
        // re-check still lives inside the atomic block below.
        guard await configStore.plugins().contains(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        let manifest = try loadManifest(id: id)
        let currentHash = try currentHash(id: id, directory: directory(for: id))
        let entries = try await configStore.updatePlugins { current in
            guard let idx = current.firstIndex(where: { $0.id == id }) else {
                throw PluginError.unknownPlugin(id)
            }
            guard currentHash == current[idx].pinnedHash else {
                throw PluginError.hashMismatch(id)
            }
            var copy = current
            copy[idx] = copy[idx].enabling(capabilities: manifest.capabilities)
            return copy
        }
        guard let updated = entries.first(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        // hashMatches is true by construction — the TOFU check above passed.
        return Plugin(
            manifest: manifest,
            enabled: updated.enabled,
            order: updated.order,
            approvedCapabilities: updated.approvedCapabilities,
            pinnedHash: updated.pinnedHash,
            hashMatches: true
        )
    }

    /// Flips `enabled` off, leaving approved capabilities and pinned hash intact.
    public func disable(id: String) async throws -> Plugin {
        let entries = try await configStore.updatePlugins { current in
            guard let idx = current.firstIndex(where: { $0.id == id }) else {
                throw PluginError.unknownPlugin(id)
            }
            var copy = current
            copy[idx] = copy[idx].disabling()
            return copy
        }
        guard let updated = entries.first(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        return try view(for: updated)
    }

    /// Removes the plugin state entry and deletes the installed directory.
    public func remove(id: String) async throws {
        _ = try await configStore.updatePlugins { current in
            guard current.contains(where: { $0.id == id }) else {
                throw PluginError.unknownPlugin(id)
            }
            return Self.renumber(current.filter { $0.id != id })
        }
        hashCache[id] = nil  // invalidate any memoised digest for this id
        // State is already committed; a failed directory delete must not throw,
        // but it must not be swallowed silently either (CLAUDE.md §12).
        do {
            try fm.removeItem(at: try directory(for: id))
        } catch {
            logger.warning(
                "remove: failed to delete plugin directory",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
        }
    }

    /// Moves `id` to `index` in the chain and renumbers `order` densely (0..<n).
    public func reorder(id: String, to index: Int) async throws -> [Plugin] {
        let entries = try await configStore.updatePlugins { current in
            let sorted = current.sorted { $0.order < $1.order }
            guard let from = sorted.firstIndex(where: { $0.id == id }) else {
                throw PluginError.unknownPlugin(id)
            }
            var arr = sorted
            let moved = arr.remove(at: from)
            let clamped = max(0, min(index, arr.count))
            arr.insert(moved, at: clamped)
            return Self.renumber(arr)
        }
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

    /// Reassigns dense `order` values following array position.
    private static func renumber(_ entries: [PluginStateEntry]) -> [PluginStateEntry] {
        entries.enumerated().map { $1.with(order: $0) }
    }
}
