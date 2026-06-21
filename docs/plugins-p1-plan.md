# Plugins — Plan d'implémentation P1 (socle : manifest + registry + état + CLI)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Livrer le socle de gestion des plugins — découverte sur disque, validation de manifest, état persisté (activé/ordre/capabilities approuvées/hash épinglé TOFU), exposé via méthodes admin et la CLI `iris plugin` — **sans aucun runtime ni sandbox** (P2+).

**Architecture:** Un nouveau module `Sources/IrisKit/Plugins/` ajoute des modèles `Codable` (manifest, état, vue), un `PluginRegistry` (acteur) qui fusionne les manifests découverts dans le répertoire par-utilisateur avec l'état persisté dans `config.json` via `ConfigStore`, un hash de contenu SHA-256 (swift-crypto) pour le TOFU, des méthodes JSON-RPC admin, et un groupe de sous-commandes CLI. Aucun processus plugin n'est lancé en P1 : `enable`/`disable` ne font que persister l'intention ; P2 branchera le lifecycle qui réagit à cet état.

**Tech Stack:** Swift 5.9 / SwiftPM · `Foundation` · `swift-crypto` (`Crypto.SHA256`, déjà autorisée) · `swift-argument-parser` · `XCTest` · acteurs Swift Concurrency.

**Référence design :** `docs/plugins-design.md` (§5 manifest, §7 provenance/état, §9 modèle de données, §10 CLI, §13 phasage).

> **Convention de wire format :** le repo encode tout en **snake_case** (`allowed_hosts`, `on_exfil_attempt`). Le `plugin.json` suit la même convention (`api_version`, `path_regex`, `on_failure`, `timeout_ms`) — divergence assumée vs l'exemple camelCase illustratif du design doc, au profit de la cohérence repo (`CLAUDE.md §11`) et de la réutilisation des encodeurs existants.

---

## Structure de fichiers (P1)

**Créés :**
- `Sources/IrisKit/Plugins/PluginManifest.swift` — schéma du `plugin.json` (manifest + hook + match + capabilities) + `PluginError`.
- `Sources/IrisKit/Plugins/PluginStateEntry.swift` — état persisté par plugin (dans `config.json`).
- `Sources/IrisKit/Plugins/PluginHasher.swift` — hash SHA-256 stable d'un répertoire (TOFU).
- `Sources/IrisKit/Plugins/Plugin.swift` — vue assemblée (manifest + état + statut dérivé).
- `Sources/IrisKit/Plugins/PluginRegistry.swift` — acteur : découverte + install/enable/disable/remove/reorder.
- `Sources/iris/Commands/PluginCommands.swift` — groupe CLI `iris plugin`.
- Tests : `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`, `ConfigPluginsTests.swift`, `PluginHasherTests.swift`, `PluginRegistryTests.swift` ; cas plugin dans `Tests/IrisKitTests/AdminDispatcherTests.swift`.

**Modifiés :**
- `Sources/IrisKit/Config/Config.swift` — champ `plugins: [PluginStateEntry]` + décodage tolérant + défaut + validation.
- `Sources/IrisKit/Config/ConfigStore.swift` — getter `plugins` + writer `setPlugins`.
- `Sources/IrisKit/IPC/AdminProtocol.swift` — cases `AdminMethod` + params/results plugin.
- `Sources/IrisKit/IPC/AdminDispatcher.swift` — propriété `pluginRegistry` + init + cases du switch + mapping d'erreur.
- `Sources/irisd/App.swift` — flag `--plugins-path` + résolution + threading.
- `Sources/irisd/Daemon.swift` — construction du `PluginRegistry` + passage au dispatcher.
- `Sources/iris/IrisCLI.swift` — enregistrement de `PluginCommand`.

---

## Task 1 : Modèle de manifest (`PluginManifest` + sous-types + `PluginError`)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginManifest.swift`
- Test: `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`

- [ ] **Step 1 : Écrire le test qui échoue**

```swift
import XCTest
@testable import IrisKit

final class PluginManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> PluginManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(PluginManifest.self, from: Data(json.utf8))
    }

    func testDecodesFullManifest() throws {
        let m = try decode(#"""
        {
          "id": "org.example.header-tagger",
          "name": "Header Tagger",
          "version": "1.0.0",
          "description": "Tags POST /v1/* requests.",
          "api_version": 1,
          "executable": "bin/header-tagger",
          "hooks": [
            { "event": "on_request",
              "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "path_regex": "^/v1/" },
              "mutates": true, "on_failure": "skip", "timeout_ms": 200 }
          ],
          "capabilities": { "network": [], "filesystem": ["scratch"] }
        }
        """#)
        XCTAssertEqual(m.id, "org.example.header-tagger")
        XCTAssertEqual(m.apiVersion, 1)
        XCTAssertEqual(m.executable, "bin/header-tagger")
        XCTAssertEqual(m.hooks.count, 1)
        XCTAssertEqual(m.hooks[0].event, .onRequest)
        XCTAssertEqual(m.hooks[0].onFailure, .skip)
        XCTAssertEqual(m.hooks[0].timeoutMs, 200)
        XCTAssertEqual(m.hooks[0].match.hosts, ["api.anthropic.com"])
        XCTAssertEqual(m.capabilities.filesystem, ["scratch"])
    }

    func testDefaultsForOmittedFields() throws {
        let m = try decode(#"""
        { "id": "a.b", "name": "B", "version": "0.1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ] }
        """#)
        XCTAssertEqual(m.description, "")
        XCTAssertEqual(m.hooks[0].mutates, false)
        XCTAssertEqual(m.hooks[0].onFailure, .skip)
        XCTAssertEqual(m.hooks[0].timeoutMs, 1000)
        XCTAssertTrue(m.capabilities.network.isEmpty)
        XCTAssertTrue(m.hooks[0].match.methods.isEmpty)
    }

    func testValidateRejectsPathTraversalId() throws {
        let m = try decode(#"""
        { "id": "../evil", "name": "E", "version": "1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ] }
        """#)
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.invalidManifest = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
    }

    func testValidateRejectsUnsupportedApiVersion() throws {
        let m = try decode(#"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 99, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ] }
        """#)
        XCTAssertThrowsError(try m.validate()) { error in
            guard case PluginError.unsupportedApiVersion(99) = error else {
                return XCTFail("expected unsupportedApiVersion, got \(error)")
            }
        }
    }

    func testValidateRejectsAbsoluteExecutable() throws {
        let m = try decode(#"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "/bin/sh",
          "hooks": [ { "event": "on_request", "match": {} } ] }
        """#)
        XCTAssertThrowsError(try m.validate())
    }
}
```

- [ ] **Step 2 : Lancer le test, vérifier qu'il échoue**

Run: `swift test --filter PluginManifestTests`
Expected: FAIL à la compilation (`cannot find 'PluginManifest' in scope`).

- [ ] **Step 3 : Implémenter les modèles**

Create `Sources/IrisKit/Plugins/PluginManifest.swift`:

```swift
import Foundation

/// Supported plugin API contract version. Iris refuses manifests declaring
/// any other value (forward/backward incompatibility is explicit, never silent).
public let pluginSupportedApiVersion = 1

/// Declarative description of a plugin, parsed from its `plugin.json`.
/// P1 models the full schema but only `onRequest` is dispatched (P3); response
/// hooks and config schema are reserved for later phases.
public struct PluginManifest: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let apiVersion: Int
    public let executable: String
    public let hooks: [PluginHook]
    public let capabilities: PluginCapabilities

    enum CodingKeys: String, CodingKey {
        case id, name, version, description
        case apiVersion = "api_version"
        case executable, hooks, capabilities
    }

    public init(
        id: String,
        name: String,
        version: String,
        description: String = "",
        apiVersion: Int = pluginSupportedApiVersion,
        executable: String,
        hooks: [PluginHook],
        capabilities: PluginCapabilities = PluginCapabilities()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.apiVersion = apiVersion
        self.executable = executable
        self.hooks = hooks
        self.capabilities = capabilities
    }

    /// Tolerant decode: optional fields default rather than failing, so a
    /// minimal hand-written manifest stays valid.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        self.executable = try c.decode(String.self, forKey: .executable)
        self.hooks = try c.decodeIfPresent([PluginHook].self, forKey: .hooks) ?? []
        self.capabilities =
            try c.decodeIfPresent(PluginCapabilities.self, forKey: .capabilities)
            ?? PluginCapabilities()
    }

    /// Structural + security validation. Rejects path-traversal in `id`/`executable`
    /// (both are used to build filesystem paths) and unsupported API versions.
    public func validate() throws {
        guard Self.isSafePathComponent(id) else {
            throw PluginError.invalidManifest("invalid id: \(id)")
        }
        guard !name.isEmpty else { throw PluginError.invalidManifest("empty name") }
        guard !version.isEmpty else { throw PluginError.invalidManifest("empty version") }
        guard apiVersion == pluginSupportedApiVersion else {
            throw PluginError.unsupportedApiVersion(apiVersion)
        }
        guard !executable.isEmpty,
            !executable.hasPrefix("/"),
            !executable.split(separator: "/").contains("..")
        else {
            throw PluginError.invalidManifest("invalid executable path: \(executable)")
        }
        guard !hooks.isEmpty else { throw PluginError.invalidManifest("no hooks declared") }
    }

    /// A single, non-traversing, filesystem-safe path component.
    static func isSafePathComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != ".." else { return false }
        guard !s.contains("/"), !s.contains("\u{0}") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct PluginHook: Codable, Sendable, Hashable {
    public let event: HookEvent
    public let match: HookMatch
    public let mutates: Bool
    public let onFailure: FailureMode
    public let timeoutMs: Int

    public enum HookEvent: String, Codable, Sendable, CaseIterable {
        case onRequest = "on_request"
        // on_response / on_complete reserved for later phases.
    }

    public enum FailureMode: String, Codable, Sendable, CaseIterable {
        case skip   // continue the chain without this plugin (default, transformers)
        case block  // fail the request closed (policy plugins)
    }

    enum CodingKeys: String, CodingKey {
        case event, match, mutates
        case onFailure = "on_failure"
        case timeoutMs = "timeout_ms"
    }

    public init(
        event: HookEvent,
        match: HookMatch,
        mutates: Bool = false,
        onFailure: FailureMode = .skip,
        timeoutMs: Int = 1000
    ) {
        self.event = event
        self.match = match
        self.mutates = mutates
        self.onFailure = onFailure
        self.timeoutMs = timeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.event = try c.decode(HookEvent.self, forKey: .event)
        self.match = try c.decodeIfPresent(HookMatch.self, forKey: .match) ?? HookMatch()
        self.mutates = try c.decodeIfPresent(Bool.self, forKey: .mutates) ?? false
        self.onFailure = try c.decodeIfPresent(FailureMode.self, forKey: .onFailure) ?? .skip
        self.timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 1000
    }
}

/// Trigger conditions. P1 stores them; P3 evaluates them before any IPC.
public struct HookMatch: Codable, Sendable, Hashable {
    public let hosts: [String]
    public let methods: [String]
    public let pathRegex: String?
    public let contentType: String?

    enum CodingKeys: String, CodingKey {
        case hosts, methods
        case pathRegex = "path_regex"
        case contentType = "content_type"
    }

    public init(
        hosts: [String] = [],
        methods: [String] = [],
        pathRegex: String? = nil,
        contentType: String? = nil
    ) {
        self.hosts = hosts
        self.methods = methods
        self.pathRegex = pathRegex
        self.contentType = contentType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self.methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
        self.pathRegex = try c.decodeIfPresent(String.self, forKey: .pathRegex)
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
    }
}

/// Declared sandbox needs. Empty = no egress / no extra filesystem (deny-by-default).
public struct PluginCapabilities: Codable, Sendable, Hashable, Equatable {
    public let network: [String]      // host:port allowed for egress
    public let filesystem: [String]   // e.g. ["scratch"]

    public init(network: [String] = [], filesystem: [String] = []) {
        self.network = network
        self.filesystem = filesystem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        self.filesystem = try c.decodeIfPresent([String].self, forKey: .filesystem) ?? []
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case unsupportedApiVersion(Int)
    case duplicateId(String)
    case unknownPlugin(String)
    case hashMismatch(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "Invalid plugin manifest: \(reason)"
        case .unsupportedApiVersion(let v): return "Unsupported plugin api_version: \(v)"
        case .duplicateId(let id): return "Plugin already installed: \(id)"
        case .unknownPlugin(let id): return "Unknown plugin: \(id)"
        case .hashMismatch(let id): return "Plugin content changed since approval: \(id)"
        case .ioError(let msg): return "Plugin I/O error: \(msg)"
        }
    }
}
```

- [ ] **Step 4 : Lancer le test, vérifier qu'il passe**

Run: `swift test --filter PluginManifestTests`
Expected: PASS (5 tests).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Tests/IrisKitTests/Plugins/PluginManifestTests.swift
git commit -m "feat(plugins): manifest model + validation"
```

---

## Task 2 : État persisté (`PluginStateEntry`) + intégration `Config` rétro-compatible

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginStateEntry.swift`
- Modify: `Sources/IrisKit/Config/Config.swift` (struct `Config` lignes 3-57, `validate()` lignes 171-180)
- Modify: `Sources/IrisKit/Config/ConfigStore.swift` (getter + writer)
- Test: `Tests/IrisKitTests/Plugins/ConfigPluginsTests.swift`

- [ ] **Step 1 : Écrire le test qui échoue** (round-trip + rétro-compat)

```swift
import XCTest
@testable import IrisKit
import Logging

final class ConfigPluginsTests: XCTestCase {
    var tmpDir: URL!
    var path: URL!
    let logger = Logger(label: "t")

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-cfg-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        path = tmpDir.appendingPathComponent("config.json")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmpDir) }

    func testDefaultConfigHasEmptyPlugins() {
        XCTAssertTrue(Config.default.plugins.isEmpty)
    }

    func testDecodesLegacyConfigWithoutPluginsKey() throws {
        // A config.json written before the plugins feature has no `plugins` key.
        let legacy = #"""
        { "version": 1,
          "broker": { "listen": "127.0.0.1:8888", "events_listen": "127.0.0.1:8899",
                      "admin_socket": "~/x.sock", "log_level": "info",
                      "event_retention_days": 7, "event_ring_size": 10000 },
          "security": { "on_exfil_attempt": "block_and_notify", "max_substitutions_per_minute": 60 },
          "backups": { "max_count": 10 },
          "hosts": [] }
        """#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let cfg = try d.decode(Config.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.plugins, [])
    }

    func testSetPluginsPersistsAndReloads() async throws {
        let store = try ConfigStore(path: path, logger: logger)
        let entry = PluginStateEntry(
            id: "org.example.tagger", enabled: true, order: 0,
            approvedCapabilities: PluginCapabilities(network: [], filesystem: ["scratch"]),
            pinnedHash: "abc123", configValues: ["mode": "fast"]
        )
        try await store.setPlugins([entry])
        let reloaded = try await ConfigStore(path: path, logger: logger).current
        XCTAssertEqual(reloaded.plugins, [entry])
    }
}
```

- [ ] **Step 2 : Lancer le test, vérifier qu'il échoue**

Run: `swift test --filter ConfigPluginsTests`
Expected: FAIL (`value of type 'Config' has no member 'plugins'`).

- [ ] **Step 3 : Implémenter `PluginStateEntry`**

Create `Sources/IrisKit/Plugins/PluginStateEntry.swift`:

```swift
import Foundation

/// Per-plugin state persisted in `config.json` (never in Keychain — non-secret).
/// The source of truth for the *installed set*: a plugin exists iff it has an entry.
public struct PluginStateEntry: Codable, Sendable, Hashable {
    public let id: String
    public let enabled: Bool
    public let order: Int
    /// Capabilities the user approved at enable time (nil = never enabled yet).
    public let approvedCapabilities: PluginCapabilities?
    /// TOFU: SHA-256 of the plugin directory pinned at install time.
    public let pinnedHash: String
    /// Non-secret plugin config values (schema-driven UI lands in a later phase).
    public let configValues: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, enabled, order
        case approvedCapabilities = "approved_capabilities"
        case pinnedHash = "pinned_hash"
        case configValues = "config_values"
    }

    public init(
        id: String,
        enabled: Bool,
        order: Int,
        approvedCapabilities: PluginCapabilities?,
        pinnedHash: String,
        configValues: [String: String] = [:]
    ) {
        self.id = id
        self.enabled = enabled
        self.order = order
        self.approvedCapabilities = approvedCapabilities
        self.pinnedHash = pinnedHash
        self.configValues = configValues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.approvedCapabilities =
            try c.decodeIfPresent(PluginCapabilities.self, forKey: .approvedCapabilities)
        self.pinnedHash = try c.decode(String.self, forKey: .pinnedHash)
        self.configValues = try c.decodeIfPresent([String: String].self, forKey: .configValues) ?? [:]
    }
}
```

- [ ] **Step 4 : Câbler `plugins` dans `Config`**

In `Sources/IrisKit/Config/Config.swift`, modify the `Config` struct (lines 3-57):

```swift
public struct Config: Codable, Sendable, Hashable {
    public let version: Int
    public let broker: BrokerConfig
    public let security: SecurityConfig
    public let backups: BackupsConfig
    public let hosts: [HostEntry]
    public let plugins: [PluginStateEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case broker
        case security
        case backups
        case hosts
        case plugins
    }

    public init(
        version: Int = 1,
        broker: BrokerConfig,
        security: SecurityConfig,
        backups: BackupsConfig,
        hosts: [HostEntry],
        plugins: [PluginStateEntry] = []
    ) {
        self.version = version
        self.broker = broker
        self.security = security
        self.backups = backups
        self.hosts = hosts
        self.plugins = plugins
    }

    /// Forward-compatible decode: a `config.json` written before the plugins
    /// feature has no `plugins` key — default it to `[]` rather than failing
    /// (same tolerance pattern as `HostEntry.init(from:)`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.broker = try c.decode(BrokerConfig.self, forKey: .broker)
        self.security = try c.decode(SecurityConfig.self, forKey: .security)
        self.backups = try c.decode(BackupsConfig.self, forKey: .backups)
        self.hosts = try c.decode([HostEntry].self, forKey: .hosts)
        self.plugins = try c.decodeIfPresent([PluginStateEntry].self, forKey: .plugins) ?? []
    }

    /// Built-in defaults, used to seed `config.json` on first run.
    public static let `default` = Config(
        version: 1,
        broker: BrokerConfig(
            listen: "127.0.0.1:8888",
            eventsListen: "127.0.0.1:8899",
            adminSocket: "~/Library/Application Support/iris/admin.sock",
            logLevel: .info,
            eventRetentionDays: 7,
            eventRingSize: 10_000
        ),
        security: SecurityConfig(
            onExfilAttempt: .blockAndNotify,
            maxSubstitutionsPerMinute: 60
        ),
        backups: BackupsConfig(maxCount: 10),
        hosts: [HostEntry(host: "api.anthropic.com", origin: .builtin, createdAt: Date(timeIntervalSince1970: 0))],
        plugins: []
    )

    /// Returns a copy with `hosts` replaced.
    public func with(hosts: [HostEntry]) -> Config {
        Config(
            version: version, broker: broker, security: security,
            backups: backups, hosts: hosts, plugins: plugins
        )
    }

    /// Returns a copy with `plugins` replaced.
    public func with(plugins: [PluginStateEntry]) -> Config {
        Config(
            version: version, broker: broker, security: security,
            backups: backups, hosts: hosts, plugins: plugins
        )
    }
}
```

> Note : ajouter un `init(from:)` explicite supprime le `init(from:)` synthétisé — c'est voulu (rétro-compat). L'`init(to:)`/encode reste synthétisé via `CodingKeys` (qui inclut désormais `plugins`).

- [ ] **Step 5 : Étendre `ConfigStore` (getter + writer)**

In `Sources/IrisKit/Config/ConfigStore.swift`, add next to the host accessors (after `allowedHosts()`, ~line 57):

```swift
    /// Persisted plugin state entries (source of truth for the installed set).
    public func plugins() -> [PluginStateEntry] {
        config.plugins
    }

    /// Replaces the whole plugin state array and persists atomically.
    /// The `PluginRegistry` owns the merge logic; the store just writes.
    public func setPlugins(_ entries: [PluginStateEntry]) throws {
        try persist(config.with(plugins: entries))
    }
```

(`persist` validates, backs up, writes atomically, rotates backups — inherited unchanged.)

- [ ] **Step 6 : Lancer les tests, vérifier qu'ils passent**

Run: `swift test --filter ConfigPluginsTests`
Expected: PASS (3 tests).

Run: `swift test --filter ConfigStoreTests`
Expected: PASS (régression : les tests config existants doivent rester verts).

- [ ] **Step 7 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginStateEntry.swift Sources/IrisKit/Config/Config.swift Sources/IrisKit/Config/ConfigStore.swift Tests/IrisKitTests/Plugins/ConfigPluginsTests.swift
git commit -m "feat(plugins): persisted plugin state in config (backward-compatible decode)"
```

---

## Task 3 : Hash de contenu TOFU (`PluginHasher`)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginHasher.swift`
- Test: `Tests/IrisKitTests/Plugins/PluginHasherTests.swift`

- [ ] **Step 1 : Écrire le test qui échoue**

```swift
import XCTest
@testable import IrisKit

final class PluginHasherTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStableAcrossCalls() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "abc".write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try "binary".write(to: dir.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        let h1 = try PluginHasher.hash(directory: dir)
        let h2 = try PluginHasher.hash(directory: dir)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64)  // hex SHA-256
    }

    func testChangesWhenContentChanges() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("run")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let after = try PluginHasher.hash(directory: dir)
        XCTAssertNotEqual(before, after)
    }

    func testChangesWhenFileAddedOrRenamed() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let before = try PluginHasher.hash(directory: dir)
        try "x".write(to: dir.appendingPathComponent("b"), atomically: true, encoding: .utf8)
        let after = try PluginHasher.hash(directory: dir)
        XCTAssertNotEqual(before, after)  // path is folded into the digest, not just bytes
    }
}
```

- [ ] **Step 2 : Lancer le test, vérifier qu'il échoue**

Run: `swift test --filter PluginHasherTests`
Expected: FAIL (`cannot find 'PluginHasher'`).

- [ ] **Step 3 : Implémenter le hash**

Create `Sources/IrisKit/Plugins/PluginHasher.swift`:

```swift
import Crypto
import Foundation

/// Stable SHA-256 digest of a plugin directory's contents, used for the TOFU
/// pin. Both the relative path AND the bytes of every regular file are folded
/// in (sorted by path), so a rename, an added/removed file, or a content edit
/// all change the digest. Directories themselves contribute only via their
/// files' paths.
public enum PluginHasher {
    public static func hash(directory: URL) throws -> String {
        let fm = FileManager.default
        let base = directory.standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PluginError.ioError("cannot enumerate \(base.path)")
        }

        var files: [(rel: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = url.standardizedFileURL.path
                .replacingOccurrences(of: base.path + "/", with: "")
            files.append((rel: rel, url: url))
        }
        files.sort { $0.rel < $1.rel }

        var hasher = SHA256()
        for file in files {
            // Length-prefixed path then length-prefixed contents → no ambiguity
            // between e.g. ("ab","c") and ("a","bc").
            hasher.update(data: Self.lengthPrefixed(Data(file.rel.utf8)))
            let contents = try Data(contentsOf: file.url)
            hasher.update(data: Self.lengthPrefixed(contents))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
```

> `import Crypto` = swift-crypto (dépendance déjà autorisée). Si le module exposé diffère (`import _CryptoExtras` n'est pas requis ici), vérifier l'import effectif d'un fichier existant utilisant SHA-256/HMAC dans le repo avant de coder ce step.

- [ ] **Step 4 : Lancer le test, vérifier qu'il passe**

Run: `swift test --filter PluginHasherTests`
Expected: PASS (3 tests).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHasher.swift Tests/IrisKitTests/Plugins/PluginHasherTests.swift
git commit -m "feat(plugins): stable directory content hash for TOFU pin"
```

---

## Task 4 : Vue assemblée (`Plugin`) + `PluginRegistry` (découverte seule)

**Files:**
- Create: `Sources/IrisKit/Plugins/Plugin.swift`
- Create: `Sources/IrisKit/Plugins/PluginRegistry.swift`
- Test: `Tests/IrisKitTests/Plugins/PluginRegistryTests.swift`

- [ ] **Step 1 : Écrire le test qui échoue (list fusionne manifest + état)**

```swift
import XCTest
@testable import IrisKit
import Logging

final class PluginRegistryTests: XCTestCase {
    var root: URL!         // plugins directory
    var cfgDir: URL!
    var store: ConfigStore!
    let logger = Logger(label: "t")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugins-\(UUID().uuidString)")
        cfgDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugincfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        store = try ConfigStore(path: cfgDir.appendingPathComponent("config.json"), logger: logger)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cfgDir)
    }

    /// Writes a minimal valid plugin source dir, returns it.
    func writeSource(id: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"""
        { "id": "\#(id)", "name": "Tagger", "version": "1.0.0", "api_version": 1,
          "executable": "run",
          "hooks": [ { "event": "on_request", "match": { "hosts": ["api.anthropic.com"] }, "mutates": true } ],
          "capabilities": { "network": [], "filesystem": ["scratch"] } }
        """#
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: dir.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        return dir
    }

    func testInstallThenListReturnsDisabledPlugin() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }

        let installed = try await reg.install(from: src)
        XCTAssertEqual(installed.manifest.id, "org.example.tagger")
        XCTAssertFalse(installed.enabled)
        XCTAssertTrue(installed.hashMatches)
        XCTAssertEqual(installed.displayState, .disabled)

        let list = try await reg.list()
        XCTAssertEqual(list.map(\.manifest.id), ["org.example.tagger"])
        // Persisted in config too.
        XCTAssertEqual(await store.plugins().map(\.id), ["org.example.tagger"])
    }

    func testInstallRejectsDuplicate() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "dup.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        await XCTAssertThrowsErrorAsync(try await reg.install(from: src)) { error in
            XCTAssertEqual(error as? PluginError, .duplicateId("dup.id"))
        }
    }
}

// Small async-throws assertion helper (place once in the test target if absent).
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("expected error") }
    catch { handler(error) }
}
```

> Si un helper `XCTAssertThrowsErrorAsync` existe déjà dans le test target, réutiliser l'existant et ne pas redéclarer (vérifier `Tests/IrisKitTests/` avant ce step).

- [ ] **Step 2 : Lancer le test, vérifier qu'il échoue**

Run: `swift test --filter PluginRegistryTests`
Expected: FAIL (`cannot find 'PluginRegistry'`).

- [ ] **Step 3 : Implémenter `Plugin`**

Create `Sources/IrisKit/Plugins/Plugin.swift`:

```swift
import Foundation

/// A plugin as presented to the CLI/UI: its manifest plus the persisted state,
/// plus a derived display status. P1 has no running process, so `displayState`
/// is computed purely from persisted flags + the TOFU hash check.
public struct Plugin: Codable, Sendable, Hashable {
    public let manifest: PluginManifest
    public let enabled: Bool
    public let order: Int
    public let approvedCapabilities: PluginCapabilities?
    public let pinnedHash: String
    /// Whether the current on-disk content still matches the pinned hash (TOFU).
    public let hashMatches: Bool

    enum CodingKeys: String, CodingKey {
        case manifest, enabled, order
        case approvedCapabilities = "approved_capabilities"
        case pinnedHash = "pinned_hash"
        case hashMatches = "hash_matches"
    }

    public init(
        manifest: PluginManifest,
        enabled: Bool,
        order: Int,
        approvedCapabilities: PluginCapabilities?,
        pinnedHash: String,
        hashMatches: Bool
    ) {
        self.manifest = manifest
        self.enabled = enabled
        self.order = order
        self.approvedCapabilities = approvedCapabilities
        self.pinnedHash = pinnedHash
        self.hashMatches = hashMatches
    }

    public enum DisplayState: String, Codable, Sendable {
        case disabled
        case enabled
        case needsReapproval  // on-disk content changed since the pin
    }

    public var displayState: DisplayState {
        if !hashMatches { return .needsReapproval }
        return enabled ? .enabled : .disabled
    }
}
```

- [ ] **Step 4 : Implémenter `PluginRegistry` (install + list)**

Create `Sources/IrisKit/Plugins/PluginRegistry.swift`:

```swift
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

    private func directory(for id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func loadManifest(id: String) throws -> PluginManifest {
        let url = directory(for: id).appendingPathComponent("plugin.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PluginError.ioError("read manifest \(id): \(error)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PluginManifest
        do { manifest = try decoder.decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalidManifest("\(id): \(error)") }
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

    /// All installed plugins, sorted by chain order. A state entry whose
    /// manifest no longer loads is logged and skipped (it stays installed in
    /// config; a later phase can surface it as broken).
    public func list() async throws -> [Plugin] {
        let entries = await configStore.plugins()
        var out: [Plugin] = []
        for entry in entries.sorted(by: { $0.order < $1.order }) {
            do { out.append(try view(for: entry)) }
            catch {
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
        do { data = try Data(contentsOf: manifestURL) }
        catch { throw PluginError.ioError("read source manifest: \(error)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PluginManifest
        do { manifest = try decoder.decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalidManifest("\(error)") }
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
        } catch { throw PluginError.ioError("copy plugin \(manifest.id): \(error)") }

        let nextOrder = (entries.map(\.order).max() ?? -1) + 1
        let newEntry = PluginStateEntry(
            id: manifest.id, enabled: false, order: nextOrder,
            approvedCapabilities: nil, pinnedHash: hash, configValues: [:]
        )
        entries.append(newEntry)
        do { try await configStore.setPlugins(entries) }
        catch {
            try? fm.removeItem(at: dest)  // roll back the copy on persist failure
            throw error
        }
        return try view(for: newEntry)
    }
}
```

> `configStore` est un acteur ⇒ tous ses accès sont `await` (`await configStore.plugins()`, `try await configStore.setPlugins(...)`). `view(for:)`, `loadManifest`, `PluginHasher.hash` sont synchrones (`throws`).

- [ ] **Step 5 : Lancer les tests, vérifier qu'ils passent**

Run: `swift test --filter PluginRegistryTests`
Expected: PASS (2 tests).

- [ ] **Step 6 : Commit**

```bash
git add Sources/IrisKit/Plugins/Plugin.swift Sources/IrisKit/Plugins/PluginRegistry.swift Tests/IrisKitTests/Plugins/PluginRegistryTests.swift
git commit -m "feat(plugins): registry discovery + install (TOFU pin)"
```

---

## Task 5 : Mutations du registry (`enable` / `disable` / `remove` / `reorder`)

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRegistry.swift`
- Test: `Tests/IrisKitTests/Plugins/PluginRegistryTests.swift` (ajouts)

- [ ] **Step 1 : Écrire les tests qui échouent**

Add to `PluginRegistryTests`:

```swift
    func testEnableApprovesCapabilitiesAndSetsFlag() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)

        let enabled = try await reg.enable(id: "org.example.tagger")
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.displayState, .enabled)
        // Declared capabilities are now the approved ones.
        XCTAssertEqual(enabled.approvedCapabilities, PluginCapabilities(network: [], filesystem: ["scratch"]))
    }

    func testEnableThrowsOnHashMismatch() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "org.example.tagger")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        // Tamper with the installed copy after the pin.
        let runFile = root.appendingPathComponent("org.example.tagger/run")
        try "#!/bin/sh\necho tampered\n".write(to: runFile, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await reg.enable(id: "org.example.tagger")) { error in
            XCTAssertEqual(error as? PluginError, .hashMismatch("org.example.tagger"))
        }
    }

    func testDisable() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "p.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        _ = try await reg.enable(id: "p.id")
        let disabled = try await reg.disable(id: "p.id")
        XCTAssertFalse(disabled.enabled)
    }

    func testRemoveDeletesDirAndState() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        let src = try writeSource(id: "p.id")
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await reg.install(from: src)
        try await reg.remove(id: "p.id")
        XCTAssertEqual(await store.plugins().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("p.id").path))
    }

    func testReorderRenumbersByPosition() async throws {
        let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
        for id in ["a.1", "a.2", "a.3"] {
            let src = try writeSource(id: id)
            _ = try await reg.install(from: src)
            try? FileManager.default.removeItem(at: src)
        }
        // Move a.3 to the front.
        let reordered = try await reg.reorder(id: "a.3", to: 0)
        XCTAssertEqual(reordered.map(\.manifest.id), ["a.3", "a.1", "a.2"])
        XCTAssertEqual(reordered.map(\.order), [0, 1, 2])
    }
```

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `swift test --filter PluginRegistryTests`
Expected: FAIL (`value of type 'PluginRegistry' has no member 'enable'`).

- [ ] **Step 3 : Implémenter les mutations**

Add to `PluginRegistry` (inside the actor):

```swift
    /// Approves the manifest's declared capabilities and flips `enabled` on.
    /// Refuses if the on-disk content drifted from the pinned hash (TOFU).
    public func enable(id: String) async throws -> Plugin {
        var entries = await configStore.plugins()
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        let manifest = try loadManifest(id: id)
        let currentHash = try PluginHasher.hash(directory: directory(for: id))
        guard currentHash == entries[idx].pinnedHash else {
            throw PluginError.hashMismatch(id)
        }
        let old = entries[idx]
        entries[idx] = PluginStateEntry(
            id: old.id, enabled: true, order: old.order,
            approvedCapabilities: manifest.capabilities,
            pinnedHash: old.pinnedHash, configValues: old.configValues
        )
        try await configStore.setPlugins(entries)
        return try view(for: entries[idx])
    }

    public func disable(id: String) async throws -> Plugin {
        var entries = await configStore.plugins()
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        let old = entries[idx]
        entries[idx] = PluginStateEntry(
            id: old.id, enabled: false, order: old.order,
            approvedCapabilities: old.approvedCapabilities,
            pinnedHash: old.pinnedHash, configValues: old.configValues
        )
        try await configStore.setPlugins(entries)
        return try view(for: entries[idx])
    }

    public func remove(id: String) async throws {
        var entries = await configStore.plugins()
        guard entries.contains(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        entries.removeAll { $0.id == id }
        try await configStore.setPlugins(Self.renumber(entries))
        try? fm.removeItem(at: directory(for: id))
    }

    /// Moves `id` to `index` in the chain and renumbers `order` densely (0..<n).
    public func reorder(id: String, to index: Int) async throws -> [Plugin] {
        var entries = await configStore.plugins().sorted { $0.order < $1.order }
        guard let from = entries.firstIndex(where: { $0.id == id }) else {
            throw PluginError.unknownPlugin(id)
        }
        let moved = entries.remove(at: from)
        let clamped = max(0, min(index, entries.count))
        entries.insert(moved, at: clamped)
        let renumbered = Self.renumber(entries)
        try await configStore.setPlugins(renumbered)
        var out: [Plugin] = []
        for entry in renumbered {
            do { out.append(try view(for: entry)) }
            catch { logger.warning("plugin skipped", metadata: ["id": "\(entry.id)"]) }
        }
        return out
    }

    /// Reassigns dense `order` values following array position.
    private static func renumber(_ entries: [PluginStateEntry]) -> [PluginStateEntry] {
        entries.enumerated().map { i, e in
            PluginStateEntry(
                id: e.id, enabled: e.enabled, order: i,
                approvedCapabilities: e.approvedCapabilities,
                pinnedHash: e.pinnedHash, configValues: e.configValues
            )
        }
    }
```

- [ ] **Step 4 : Lancer, vérifier le succès**

Run: `swift test --filter PluginRegistryTests`
Expected: PASS (7 tests au total).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRegistry.swift Tests/IrisKitTests/Plugins/PluginRegistryTests.swift
git commit -m "feat(plugins): registry enable/disable/remove/reorder with TOFU enforcement"
```

---

## Task 6 : Méthodes admin (`plugin.*`) + dispatch

**Files:**
- Modify: `Sources/IrisKit/IPC/AdminProtocol.swift` (enum `AdminMethod` lignes 5-31 ; ajouter params/results)
- Modify: `Sources/IrisKit/IPC/AdminDispatcher.swift` (propriété + init lignes 14-51 ; switch lignes ~112+ ; mapping d'erreur dans `dispatch` lignes ~55-108)
- Test: `Tests/IrisKitTests/AdminDispatcherTests.swift` (ajouts) + `makeDispatcher` helper

- [ ] **Step 1 : Écrire le test qui échoue**

Add to `AdminDispatcherTests`. First extend the existing `makeDispatcher` helper to build a `PluginRegistry` over temp dirs and pass it to `AdminDispatcher` (mirror the existing wiring); then:

```swift
    func testPluginInstallListEnableRemove() async throws {
        // Build a dispatcher whose registry uses a temp plugins dir (see helper).
        let (dispatcher, ctx) = try await makeDispatcherWithPlugins()
        defer { ctx.cleanup() }

        // install
        let installResp = await dispatcher.dispatch(
            request(.pluginInstall, params: try JSONValue.encoding(
                PluginInstallParams(path: ctx.sourceDir.path)))
        )
        let installed = try unwrapResult(installResp).decode(as: Plugin.self)
        XCTAssertEqual(installed.manifest.id, "org.example.tagger")
        XCTAssertFalse(installed.enabled)

        // list
        let listResp = await dispatcher.dispatch(request(.pluginList))
        let list = try unwrapResult(listResp).decode(as: [Plugin].self)
        XCTAssertEqual(list.map(\.manifest.id), ["org.example.tagger"])

        // enable
        let enableResp = await dispatcher.dispatch(
            request(.pluginEnable, params: try JSONValue.encoding(
                PluginIdParams(id: "org.example.tagger")))
        )
        XCTAssertTrue(try unwrapResult(enableResp).decode(as: Plugin.self).enabled)

        // remove
        let removeResp = await dispatcher.dispatch(
            request(.pluginRemove, params: try JSONValue.encoding(
                PluginIdParams(id: "org.example.tagger")))
        )
        XCTAssertTrue(try unwrapResult(removeResp).decode(as: PluginRemovedResult.self).removed)
    }

    func testPluginUnknownMapsToError() async throws {
        let (dispatcher, ctx) = try await makeDispatcherWithPlugins()
        defer { ctx.cleanup() }
        let resp = await dispatcher.dispatch(
            request(.pluginInfo, params: try JSONValue.encoding(PluginIdParams(id: "nope")))
        )
        XCTAssertNotNil(resp.error)  // unknownPlugin → JSON-RPC error
    }
```

> Le helper `makeDispatcherWithPlugins()` crée : un `ConfigStore` temp, un répertoire plugins temp, un dossier source `org.example.tagger` (manifest + `run`), construit le `PluginRegistry`, et renvoie le dispatcher + un contexte avec `sourceDir` et un `cleanup()`. Calquer sur `makeDispatcher` existant (lignes 44-60) en ajoutant l'argument `pluginRegistry:`.

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `swift test --filter AdminDispatcherTests`
Expected: FAIL (`type 'AdminMethod' has no member 'pluginInstall'`).

- [ ] **Step 3 : Ajouter les méthodes au protocole**

In `Sources/IrisKit/IPC/AdminProtocol.swift`, add cases to `AdminMethod` (after `adminUninstall`):

```swift
    case pluginList = "plugin.list"
    case pluginInfo = "plugin.info"
    case pluginInstall = "plugin.install"
    case pluginEnable = "plugin.enable"
    case pluginDisable = "plugin.disable"
    case pluginRemove = "plugin.remove"
    case pluginReorder = "plugin.reorder"
```

Add param/result types (next to the other param structs):

```swift
public struct PluginInstallParams: Codable, Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct PluginIdParams: Codable, Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct PluginReorderParams: Codable, Sendable, Equatable {
    public let id: String
    public let index: Int
    public init(id: String, index: Int) {
        self.id = id
        self.index = index
    }
}

public struct PluginRemovedResult: Codable, Sendable, Equatable {
    public let removed: Bool
    public init(removed: Bool) { self.removed = removed }
}
```

- [ ] **Step 4 : Injecter `pluginRegistry` + router**

In `Sources/IrisKit/IPC/AdminDispatcher.swift`:

(a) Add stored property after `configStore` (line 19):
```swift
    public let pluginRegistry: PluginRegistry
```
(b) Add init param after `configStore:` (line 34) and assignment (line 46):
```swift
        pluginRegistry: PluginRegistry,
```
```swift
        self.pluginRegistry = pluginRegistry
```
(c) Add cases to the `handle(_:params:)` switch (alongside the others):
```swift
        case .pluginList:
            return try JSONValue.encoding(try await pluginRegistry.list())
        case .pluginInfo:
            let p = try Self.decode(PluginIdParams.self, from: params)
            return try JSONValue.encoding(try await pluginRegistry.info(id: p.id))
        case .pluginInstall:
            let p = try Self.decode(PluginInstallParams.self, from: params)
            let url = URL(fileURLWithPath: (p.path as NSString).expandingTildeInPath)
            return try JSONValue.encoding(try await pluginRegistry.install(from: url))
        case .pluginEnable:
            let p = try Self.decode(PluginIdParams.self, from: params)
            return try JSONValue.encoding(try await pluginRegistry.enable(id: p.id))
        case .pluginDisable:
            let p = try Self.decode(PluginIdParams.self, from: params)
            return try JSONValue.encoding(try await pluginRegistry.disable(id: p.id))
        case .pluginRemove:
            let p = try Self.decode(PluginIdParams.self, from: params)
            try await pluginRegistry.remove(id: p.id)
            return try JSONValue.encoding(PluginRemovedResult(removed: true))
        case .pluginReorder:
            let p = try Self.decode(PluginReorderParams.self, from: params)
            return try JSONValue.encoding(try await pluginRegistry.reorder(id: p.id, to: p.index))
```
(d) Add a `PluginError` mapping in `dispatch(_:)` (next to the other typed `catch` clauses, ~line 70):
```swift
        } catch let error as PluginError {
            return .failure(id: request.id, error: Self.mapPluginError(error))
```
(e) Add the mapper (next to `mapSecretStoreError`):
```swift
    static func mapPluginError(_ error: PluginError) -> JSONRPCError {
        switch error {
        case .unknownPlugin:
            return JSONRPCError(code: -32030, message: error.localizedDescription)
        case .duplicateId:
            return JSONRPCError(code: -32031, message: error.localizedDescription)
        case .hashMismatch:
            return JSONRPCError(code: -32032, message: error.localizedDescription)
        case .invalidManifest, .unsupportedApiVersion:
            return JSONRPCError(code: -32033, message: error.localizedDescription)
        case .ioError:
            return JSONRPCError(code: -32034, message: error.localizedDescription)
        }
    }
```

> Vérifier le constructeur exact de `JSONRPCError` (cf. `JSONRPC.swift:156-160` : `JSONRPCError(code:message:)`). Les codes -32030..-32034 sont libres (les codes iris existants vont jusqu'à -32011/-32001).

- [ ] **Step 5 : Lancer, vérifier le succès**

Run: `swift test --filter AdminDispatcherTests`
Expected: PASS (les nouveaux tests + non-régression des existants).

- [ ] **Step 6 : Commit**

```bash
git add Sources/IrisKit/IPC/AdminProtocol.swift Sources/IrisKit/IPC/AdminDispatcher.swift Tests/IrisKitTests/AdminDispatcherTests.swift
git commit -m "feat(plugins): admin RPC methods (plugin.list/install/enable/disable/remove/reorder/info)"
```

---

## Task 7 : Câblage daemon (construction du registry + flag `--plugins-path`)

**Files:**
- Modify: `Sources/irisd/App.swift` (flags lignes 18-28 ; résolution lignes 57-77 ; appel `Daemon`)
- Modify: `Sources/irisd/Daemon.swift` (init + construction dispatcher ligne 152)

- [ ] **Step 1 : Ajouter le flag + résoudre le répertoire**

In `Sources/irisd/App.swift`, after the `caPath` option (line 28):

```swift
    @Option(
        name: .long,
        help: "Plugins directory (default ~/Library/Application Support/iris/plugins)."
    )
    var pluginsPath: String?
```

After the CA path resolution (~line 77), add:

```swift
        let resolvedPluginsDir: URL =
            pluginsPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(
                fileURLWithPath: ("~/Library/Application Support/iris/plugins" as NSString)
                    .expandingTildeInPath
            )
```

Pass `pluginsDirectory: resolvedPluginsDir` into the `Daemon(...)` construction call (add the argument where `Daemon` is instantiated).

- [ ] **Step 2 : Threader dans `Daemon` + construire le registry**

In `Sources/irisd/Daemon.swift`:

(a) Add a `pluginsDirectory: URL` parameter to `Daemon`'s initializer (mirror how `configStore`/`caManager` are received).

(b) Before the `AdminDispatcher(` construction (line 152), build the registry:
```swift
        let pluginRegistry = PluginRegistry(
            pluginsDirectory: pluginsDirectory,
            configStore: configStore,
            logger: logger
        )
```

(c) Add the argument to the `AdminDispatcher(` call (after `configStore: configStore,`):
```swift
            pluginRegistry: pluginRegistry,
```

- [ ] **Step 3 : Build complet (pas de test unitaire ; smoke d'intégration en Task 9)**

Run: `swift build`
Expected: build OK, aucune erreur de concurrence (`-strict-concurrency=complete`). `PluginRegistry` est un acteur `Sendable` → traversable par les closures du dispatcher.

- [ ] **Step 4 : Lancer toute la suite (non-régression)**

Run: `swift test`
Expected: PASS (toute la suite + nouveaux tests plugins).

- [ ] **Step 5 : Commit**

```bash
git add Sources/irisd/App.swift Sources/irisd/Daemon.swift
git commit -m "feat(plugins): wire PluginRegistry into the daemon (--plugins-path)"
```

---

## Task 8 : CLI `iris plugin`

**Files:**
- Create: `Sources/iris/Commands/PluginCommands.swift`
- Modify: `Sources/iris/IrisCLI.swift` (subcommands lignes 10-22)

- [ ] **Step 1 : Implémenter le groupe + sous-commandes**

Create `Sources/iris/Commands/PluginCommands.swift`:

```swift
import ArgumentParser
import Foundation
import IrisKit

struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins (out-of-process request/response hooks).",
        subcommands: [List.self, Install.self, Info.self, Enable.self, Disable.self, Remove.self, Reorder.self]
    )
}

extension PluginCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed plugins.")
        @OptionGroup var connection: ConnectionOptions
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugins = try await withAdminClient(connection) { client in
                try await client.call(.pluginList, returning: [Plugin].self)
            }
            let humanText: String = {
                let rows = plugins.map { p in
                    [p.manifest.id, p.displayState.rawValue, p.manifest.version,
                     "\(p.order)", p.hashMatches ? "ok" : "CHANGED"]
                }
                if rows.isEmpty { return "no plugins" }
                return TextFormatter.table(
                    headers: ["ID", "STATE", "VERSION", "ORDER", "HASH"], rows: rows)
            }()
            try Output.print(humanText: humanText, jsonValue: plugins, json: json)
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a plugin from a directory.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Path to the plugin source directory (containing plugin.json).") var path: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(.pluginInstall, params: PluginInstallParams(path: path), returning: Plugin.self)
            }
            try Output.print(
                humanText: "installed \(plugin.manifest.id) (disabled). Run 'iris plugin enable \(plugin.manifest.id)' to activate.",
                jsonValue: plugin, json: json)
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show a plugin's manifest and state.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(.pluginInfo, params: PluginIdParams(id: id), returning: Plugin.self)
            }
            let caps = plugin.approvedCapabilities
            let humanText = """
                id:       \(plugin.manifest.id)
                name:     \(plugin.manifest.name)
                version:  \(plugin.manifest.version)
                state:    \(plugin.displayState.rawValue)
                order:    \(plugin.order)
                hash:     \(plugin.hashMatches ? "ok" : "CHANGED — re-approval required")
                network:  \(caps?.network.joined(separator: ", ") ?? "(not approved)")
                files:    \(caps?.filesystem.joined(separator: ", ") ?? "(not approved)")
                """
            try Output.print(humanText: humanText, jsonValue: plugin, json: json)
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "enable", abstract: "Approve capabilities and enable a plugin.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(.pluginEnable, params: PluginIdParams(id: id), returning: Plugin.self)
            }
            try Output.print(humanText: "enabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a plugin.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugin = try await withAdminClient(connection) { client in
                try await client.call(.pluginDisable, params: PluginIdParams(id: id), returning: Plugin.self)
            }
            try Output.print(humanText: "disabled \(plugin.manifest.id)", jsonValue: plugin, json: json)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an installed plugin.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let result = try await withAdminClient(connection) { client in
                try await client.call(.pluginRemove, params: PluginIdParams(id: id), returning: PluginRemovedResult.self)
            }
            try Output.print(humanText: result.removed ? "removed \(id)" : "not removed", jsonValue: result, json: json)
        }
    }

    struct Reorder: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reorder", abstract: "Move a plugin to a position in the hook chain.")
        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Plugin id.") var id: String
        @Argument(help: "Target index (0-based).") var index: Int
        @Flag(name: .customLong("json"), help: "Emit JSON output.") var json = false

        mutating func run() async throws {
            let plugins = try await withAdminClient(connection) { client in
                try await client.call(.pluginReorder, params: PluginReorderParams(id: id, index: index), returning: [Plugin].self)
            }
            let humanText = plugins.map { "\($0.order): \($0.manifest.id)" }.joined(separator: "\n")
            try Output.print(humanText: humanText, jsonValue: plugins, json: json)
        }
    }
}
```

- [ ] **Step 2 : Enregistrer le groupe**

In `Sources/iris/IrisCLI.swift`, add to the `subcommands` array (line 10-22):

```swift
            PluginCommand.self,
```

- [ ] **Step 3 : Build**

Run: `swift build`
Expected: build OK.

- [ ] **Step 4 : Smoke CLI (registry-level, daemon éphémère isolé)**

> Le harness BLOQUE le lancement d'`irisd` via Bash (mémoire projet). Ce smoke s'exécute par l'utilisateur au Terminal (`! bash`), pas par l'agent. Il prouve le bout-en-bout CLI↔daemon sans toucher au trousseau ni à la config prod (isolation par flags `--config-path`/`--plugins-path`/`--ca-path /tmp`, cf. mémoire isolation).

```bash
set -e
TMP=$(mktemp -d)
# Plugin source d'exemple minimal
mkdir -p "$TMP/src"
cat > "$TMP/src/plugin.json" <<'JSON'
{ "id":"org.example.tagger","name":"Tagger","version":"1.0.0","api_version":1,
  "executable":"run",
  "hooks":[{"event":"on_request","match":{"hosts":["api.anthropic.com"]},"mutates":true}],
  "capabilities":{"network":[],"filesystem":["scratch"]} }
JSON
printf '#!/bin/sh\n' > "$TMP/src/run"

# Daemon éphémère isolé (config/ca/plugins hors prod)
.build/debug/irisd --foreground \
  --config-path "$TMP/config.json" \
  --ca-path /tmp/iris-smoke-ca.pem --in-memory-ca \
  --plugins-path "$TMP/plugins" &
DPID=$!
sleep 1
# La CLI lit le socket depuis --config-path (cf. ConnectionOptions.resolvedSocketPath).
IRIS=".build/debug/iris --config-path $TMP/config.json"

$IRIS plugin list                       # -> "no plugins"
$IRIS plugin install "$TMP/src"          # -> installed org.example.tagger (disabled)
$IRIS plugin list                        # -> 1 ligne, STATE=disabled, HASH=ok
$IRIS plugin enable org.example.tagger   # -> enabled
$IRIS plugin info org.example.tagger     # -> state: enabled, network/files approuvés
$IRIS plugin reorder org.example.tagger 0
$IRIS plugin disable org.example.tagger
$IRIS plugin remove org.example.tagger
$IRIS plugin list                        # -> "no plugins"

kill $DPID; rm -rf "$TMP" /tmp/iris-smoke-ca.pem
```

Critères de réussite : chaque commande retourne 0, l'état persiste entre appels (relances de `list` cohérentes), `remove` purge le dossier `$TMP/plugins/org.example.tagger`.

- [ ] **Step 5 : Commit**

```bash
git add Sources/iris/Commands/PluginCommands.swift Sources/iris/IrisCLI.swift
git commit -m "feat(plugins): iris plugin CLI (list/install/info/enable/disable/remove/reorder)"
```

---

## Task 9 : Plugin d'exemple Swift + validation finale P1

**Files:**
- Create: `examples/plugins/header-tagger/plugin.json`
- Create: `examples/plugins/header-tagger/Package.swift` + `Sources/header-tagger/main.swift` (build standalone)
- (P1 n'exécute pas le plugin : l'exemple sert de fixture d'install + doc. La logique `onRequest` réelle sera branchée et testée en P3.)

- [ ] **Step 1 : Écrire le manifest d'exemple**

Create `examples/plugins/header-tagger/plugin.json`:

```json
{
  "id": "org.iris.example.header-tagger",
  "name": "Header Tagger",
  "version": "1.0.0",
  "description": "Adds an X-Iris-Plugin header to matched requests (demo). Runtime wiring lands in P3.",
  "api_version": 1,
  "executable": ".build/release/header-tagger",
  "hooks": [
    { "event": "on_request",
      "match": { "hosts": ["api.anthropic.com"], "methods": ["POST"], "path_regex": "^/v1/" },
      "mutates": true, "on_failure": "skip", "timeout_ms": 200 }
  ],
  "capabilities": { "network": [], "filesystem": [] }
}
```

- [ ] **Step 2 : Stub exécutable Swift (le protocole JSON-RPC réel arrive en P3)**

Create `examples/plugins/header-tagger/Sources/header-tagger/main.swift`:

```swift
import Foundation

// P1: placeholder executable so the example installs as a real binary.
// P3 replaces this with the JSON-RPC-over-stdio onRequest handler that adds
// the X-Iris-Plugin header. Kept inert here on purpose.
FileHandle.standardError.write(Data("header-tagger: not yet wired (P3)\n".utf8))
```

Create `examples/plugins/header-tagger/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "header-tagger",
    targets: [ .executableTarget(name: "header-tagger") ]
)
```

- [ ] **Step 3 : Vérifier que l'exemple build et s'installe**

Run:
```bash
(cd examples/plugins/header-tagger && swift build -c release)
```
Expected: build OK, binaire à `examples/plugins/header-tagger/.build/release/header-tagger`.

(Smoke d'install via la CLI : réutiliser le script de Task 8 Step 4 en pointant `install` sur `examples/plugins/header-tagger`. À exécuter par l'utilisateur.)

- [ ] **Step 4 : Validation finale P1**

Run: `swift build && swift test && swift-format lint --recursive Sources`
Expected: build OK ; toute la suite PASS ; lint propre (`CLAUDE.md §5`).

- [ ] **Step 5 : Commit**

```bash
git add examples/plugins/header-tagger
git commit -m "feat(plugins): header-tagger example plugin (install fixture; runtime in P3)"
```

---

## Auto-revue du plan (couverture de la spec P1)

- **§5 manifest** → Task 1 (`PluginManifest` + sous-types + validation sécurité path-traversal/api_version). ✅
- **§7 provenance/install/TOFU/état** → Task 2 (état persisté), Task 3 (hash), Task 4 (install + pin), Task 5 (enable = approbation capabilities, refus sur drift de hash). ✅
- **§9 modèle de données + méthodes admin** → Task 1/2/4 (modèles), Task 6 (`plugin.*` RPC + mapping d'erreur). ✅
- **§9 intégration daemon** → Task 7 (registry injecté, `--plugins-path`). ✅
- **§10 CLI** → Task 8 (`iris plugin` 7 sous-commandes). ✅
- **§11 plugin d'exemple Swift** → Task 9 (fixture ; logique `onRequest` reportée à P3, explicitement). ✅
- **§12 tests** → couverts par tâche (manifest, config round-trip + rétro-compat, hash, registry, dispatcher). ✅

**Hors P1 (phases suivantes, non couvert ici, par conception) :** lifecycle de processus + IPC + sandbox (P2) ; dispatch `onRequest` + intégration `MITMHandler` + events plugin (P3) ; section UI Plugins (P4) ; hooks `onResponse`/config schema-driven/streaming (designs séparés).

**Risques portés en P2 (rappel §14 design) :** mécanisme d'enforcement sandbox macOS 13+ et confirmation du spawn sous hardened runtime — **spike de recherche obligatoire avant le plan P2**.

**Notes de cohérence de types :** `PluginCapabilities` est `Equatable` (comparé dans Task 5 + asserté en test) ; `Plugin`/`PluginStateEntry`/`PluginManifest` sont `Codable & Sendable & Hashable` (traversent l'IPC et l'acteur) ; le wire format est snake_case partout.
