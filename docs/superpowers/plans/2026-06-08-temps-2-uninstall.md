# TEMPS 2 — Désinstallation propre : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fournir une désinstallation propre d'IRIS via un bouton « Quit & Uninstall » in-app + un script de secours `uninstall.sh`, sans jamais supprimer les secrets sans consentement explicite.

**Architecture:** Le daemon (RPC `admin.uninstall`) est le seul à nettoyer le Keychain sans prompt (ACL 8b) ; l'app retire trust store / bloc shell / configs MCP wrappées / auto-start ; le script couvre le paquet `root` (`sudo`) et le cas « app déjà jetée ». Ordre strict : RPC daemon avant `unregister()`.

**Tech Stack:** Swift 5.9 / SwiftPM (cibles `IrisKit`, `IrisAppCore`, `iris` CLI), SwiftUI/AppKit (cible Xcode `IrisApp`), XCTest, bash, `.pkg` (`pkgbuild`/`productbuild`).

**Spec de référence :** `docs/superpowers/specs/2026-06-08-temps-2-uninstall-design.md`.

**Conventions du repo (rappel) :** indentation 4 espaces ; pas de force-unwrap hors tests ; `swift-format` avant commit ; commits conventional ; framework de test = **XCTest** ; `swift build && swift test` doivent passer ; pour la cible `IrisApp`, ajouter un `.swift` n'exige **aucune** édition pbxproj (groupe synchronisé) et l'**oracle est `swift build`/CI**, pas SourceKit.

---

## Vue d'ensemble des fichiers

**Créés :**
- `Sources/IrisKit/MCPConfig/WrappedPathsRegistry.swift` — registre des chemins wrappés (manifeste JSON).
- `Sources/IrisAppCore/Protocols/MCPUnwrapping.swift` — seam + impl prod du « unwrap tout ».
- `Tests/IrisKitTests/MCPConfig/WrappedPathsRegistryTests.swift`
- `Tests/IrisAppCoreTests/Mocks/FakeMCPUnwrapper.swift`
- `Tests/IrisAppCoreTests/AppModelUninstallTests.swift`
- `packaging/scripts/uninstall.sh` — script de secours (distribué).

**Modifiés :**
- `Sources/IrisKit/CA/CAKeyStore.swift` — ajoute `deleteKey()`.
- `Sources/IrisKit/CA/InMemoryCAKeyStore.swift`, `KeychainCAKeyStore.swift` — impls.
- `Sources/IrisKit/CA/CAManager.swift` — expose `deleteKey()`.
- `Sources/IrisKit/IPC/AdminProtocol.swift` — méthode + types `admin.uninstall`.
- `Sources/IrisKit/IPC/AdminDispatcher.swift` — handler.
- `Sources/IrisKit/MCPConfig/MCPPatcher.swift` — ajoute `unwrap(path:)`.
- `Sources/iris/Commands/MCPCommands.swift` — `Unwrap` utilise `MCPPatcher.unwrap` ; `Wrap`/`Unwrap` branchent le registre.
- `Sources/IrisAppCore/Protocols/AdminCalling.swift` — ajoute `uninstall(deleteSecrets:)`.
- `Sources/IrisAppCore/Protocols/IrisKitConformances.swift` — conformance.
- `Sources/IrisAppCore/AppModel.swift` — `uninstall(...)` + `UninstallReport` + seam `mcpUnwrapper`.
- `IrisApp/IrisApp/SettingsTab.swift` — section « Quit & Uninstall ».
- `Tests/IrisKitTests/CAManagerTests.swift`, `AdminDispatcherTests.swift`, `MCPConfig/MCPPatcherTests.swift` — tests.
- `Tests/IntegrationTests/MCPWrapFlowTests.swift` — registre dans le flux wrap/unwrap.
- `Tests/IrisAppCoreTests/Mocks/FakeAdminCalling.swift` — `uninstall(...)`.
- `packaging/scripts/postinstall` — copie `uninstall.sh` dans App Support.
- `.github/workflows/ci.yml` — `bash -n` sur le script.
- `docs/user-guide.md` — section « Désinstaller ».

---

## Task 1 : `CAKeyStore.deleteKey()` (protocole + impls)

**Files:**
- Modify: `Sources/IrisKit/CA/CAKeyStore.swift`
- Modify: `Sources/IrisKit/CA/InMemoryCAKeyStore.swift`
- Modify: `Sources/IrisKit/CA/KeychainCAKeyStore.swift`
- Test: `Tests/IrisKitTests/CAManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Ajouter dans `Tests/IrisKitTests/CAManagerTests.swift` (à l'intérieur de la classe de test existante) :

```swift
func testInMemoryKeyStoreDeleteKeyIsIdempotent() async throws {
    let store = InMemoryCAKeyStore()
    _ = try await store.loadOrGenerateKey()  // key now present
    let first = try await store.deleteKey()
    XCTAssertTrue(first, "deleting an existing key returns true")
    let loaded = try await store.loadKey()
    XCTAssertNil(loaded, "key is gone after delete")
    let second = try await store.deleteKey()
    XCTAssertFalse(second, "deleting an absent key returns false (idempotent)")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CAManagerTests/testInMemoryKeyStoreDeleteKeyIsIdempotent`
Expected: FAIL (compile error: `deleteKey` not a member).

- [ ] **Step 3: Add `deleteKey()` to the protocol**

In `Sources/IrisKit/CA/CAKeyStore.swift`, add to the protocol body:

```swift
public protocol CAKeyStore: Sendable {
    func loadKey() async throws -> P256.Signing.PrivateKey?
    func storeKey(_ key: P256.Signing.PrivateKey) async throws
    /// Removes the persisted CA private key. Returns `true` if an item was
    /// removed, `false` if none was present (idempotent).
    func deleteKey() async throws -> Bool
}
```

- [ ] **Step 4: Implement in `InMemoryCAKeyStore`**

In `Sources/IrisKit/CA/InMemoryCAKeyStore.swift`, add inside the actor:

```swift
public func deleteKey() async throws -> Bool {
    let had = key != nil
    key = nil
    return had
}
```

- [ ] **Step 5: Implement in `KeychainCAKeyStore`**

In `Sources/IrisKit/CA/KeychainCAKeyStore.swift`, add inside the actor:

```swift
public func deleteKey() async throws -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    switch status {
    case errSecSuccess:
        return true
    case errSecItemNotFound:
        return false
    default:
        throw CAError.keychainStatus(status)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter CAManagerTests/testInMemoryKeyStoreDeleteKeyIsIdempotent`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/CA/CAKeyStore.swift Sources/IrisKit/CA/InMemoryCAKeyStore.swift Sources/IrisKit/CA/KeychainCAKeyStore.swift Tests/IrisKitTests/CAManagerTests.swift
git commit -m "feat(ca): CAKeyStore.deleteKey() idempotent (protocole + impls)"
```

---

## Task 2 : `CAManager.deleteKey()`

**Files:**
- Modify: `Sources/IrisKit/CA/CAManager.swift`
- Test: `Tests/IrisKitTests/CAManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `CAManagerTests`:

```swift
func testCAManagerDeleteKeyRemovesUnderlyingKey() async throws {
    let store = InMemoryCAKeyStore()
    let manager = CAManager(keyStore: store)
    _ = try await manager.signingKey()  // generates + persists
    let deleted = try await manager.deleteKey()
    XCTAssertTrue(deleted)
    let again = try await manager.deleteKey()
    XCTAssertFalse(again)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CAManagerTests/testCAManagerDeleteKeyRemovesUnderlyingKey`
Expected: FAIL (compile error: `deleteKey` not a member of `CAManager`).

- [ ] **Step 3: Implement**

In `Sources/IrisKit/CA/CAManager.swift`, add after `signingKey()`:

```swift
/// Removes the persisted CA private key from the underlying key store.
/// Used by the admin RPC `admin.uninstall`. Returns `true` if an item was
/// removed. Does not touch the on-disk public PEM (that is the script's job).
public func deleteKey() async throws -> Bool {
    try await keyStore.deleteKey()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CAManagerTests/testCAManagerDeleteKeyRemovesUnderlyingKey`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/CA/CAManager.swift Tests/IrisKitTests/CAManagerTests.swift
git commit -m "feat(ca): CAManager.deleteKey() expose la suppression de la clé CA"
```

---

## Task 3 : RPC `admin.uninstall` (types + dispatcher)

**Files:**
- Modify: `Sources/IrisKit/IPC/AdminProtocol.swift`
- Modify: `Sources/IrisKit/IPC/AdminDispatcher.swift`
- Test: `Tests/IrisKitTests/AdminDispatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/IrisKitTests/AdminDispatcherTests.swift`. Reuse the existing helper that builds an `AdminDispatcher` over an `InMemorySecretStore` (look at the top of the file for the existing `makeDispatcher`/`dispatch` helper and mirror it; the dispatcher needs `secretStore`, `eventRing`, `caManager`, `daemon`, `configStore`). The CA manager must use an `InMemoryCAKeyStore`.

```swift
func testAdminUninstallDeletesCAKeyButKeepsSecretsWhenOptedOut() async throws {
    let secrets = InMemorySecretStore()
    _ = try await secrets.add(Data("V".utf8), named: "TOKEN", allowedHosts: ["api.example.com"], createdAt: Date())
    let keyStore = InMemoryCAKeyStore()
    let ca = CAManager(keyStore: keyStore)
    _ = try await ca.signingKey()
    let dispatcher = makeDispatcher(secretStore: secrets, caManager: ca)

    let response = await dispatcher.dispatch(
        request(method: "admin.uninstall", params: ["delete_secrets": false])
    )
    let result = try decodeSuccess(AdminUninstallResult.self, response)
    XCTAssertTrue(result.caKeyDeleted)
    XCTAssertEqual(result.secretsDeleted, 0)
    let remaining = try await secrets.list()
    XCTAssertEqual(remaining.count, 1, "secrets are NOT touched when opted out")
}

func testAdminUninstallDeletesSecretsWhenOptedInAndIsValueFree() async throws {
    let secrets = InMemorySecretStore()
    _ = try await secrets.add(Data("SUPERSECRET".utf8), named: "TOKEN", allowedHosts: ["api.example.com"], createdAt: Date())
    let ca = CAManager(keyStore: InMemoryCAKeyStore())
    _ = try await ca.signingKey()
    let dispatcher = makeDispatcher(secretStore: secrets, caManager: ca)

    let response = await dispatcher.dispatch(
        request(method: "admin.uninstall", params: ["delete_secrets": true])
    )
    let result = try decodeSuccess(AdminUninstallResult.self, response)
    XCTAssertEqual(result.secretsDeleted, 1)
    XCTAssertEqual(try await secrets.list().count, 0)

    // I3 — non-fuite : aucun octet de valeur dans la réponse encodée.
    let dump = String(data: try JSONEncoder().encode(response), encoding: .utf8) ?? ""
    XCTAssertFalse(dump.contains("SUPERSECRET"))
}

func testAdminUninstallIsIdempotent() async throws {
    let secrets = InMemorySecretStore()
    let ca = CAManager(keyStore: InMemoryCAKeyStore())
    let dispatcher = makeDispatcher(secretStore: secrets, caManager: ca)
    let response = await dispatcher.dispatch(
        request(method: "admin.uninstall", params: ["delete_secrets": true])
    )
    let result = try decodeSuccess(AdminUninstallResult.self, response)
    XCTAssertFalse(result.caKeyDeleted)
    XCTAssertEqual(result.secretsDeleted, 0)
}
```

> If `makeDispatcher`, `request`, and `decodeSuccess` helpers don't exist or have different names/signatures in this file, adapt these tests to the helpers actually present (read the top of `AdminDispatcherTests.swift` first). The dispatcher's `caManager` parameter currently may be hard-coded in the helper — extend the helper to accept a `caManager` argument with a default.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AdminDispatcherTests/testAdminUninstall`
Expected: FAIL (compile error: `AdminUninstallResult` undefined / method unknown).

- [ ] **Step 3: Add the method + types in `AdminProtocol.swift`**

In the `AdminMethod` enum, add:

```swift
    case adminUninstall = "admin.uninstall"
```

In the `// MARK: - Params` section, add:

```swift
public struct AdminUninstallParams: Codable, Sendable, Equatable {
    public let deleteSecrets: Bool
    enum CodingKeys: String, CodingKey { case deleteSecrets = "delete_secrets" }
    public init(deleteSecrets: Bool) { self.deleteSecrets = deleteSecrets }
}
```

In the `// MARK: - Results` section, add:

```swift
/// Result of `admin.uninstall`. Value-free (SPECS §6): only counts/flags.
public struct AdminUninstallResult: Codable, Sendable, Equatable {
    public let caKeyDeleted: Bool
    public let secretsDeleted: Int
    enum CodingKeys: String, CodingKey {
        case caKeyDeleted = "ca_key_deleted"
        case secretsDeleted = "secrets_deleted"
    }
    public init(caKeyDeleted: Bool, secretsDeleted: Int) {
        self.caKeyDeleted = caKeyDeleted
        self.secretsDeleted = secretsDeleted
    }
}
```

- [ ] **Step 4: Add the handler in `AdminDispatcher.swift`**

In `handle(_:params:)`, add a new `case` in the `switch` (place it next to the other `ca*` / `daemon*` cases):

```swift
        case .adminUninstall:
            let payload = try Self.decode(AdminUninstallParams.self, from: params)
            let caKeyDeleted = try await caManager.deleteKey()
            var secretsDeleted = 0
            if payload.deleteSecrets {
                for secret in try await secretStore.list() {
                    try await secretStore.delete(named: secret.name)
                    secretsDeleted += 1
                }
            }
            return try JSONValue.encoding(
                AdminUninstallResult(caKeyDeleted: caKeyDeleted, secretsDeleted: secretsDeleted)
            )
```

> No new entry is needed in `logCall` — the default branch already logs only method + id, and `admin.uninstall` params carry no secret value.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AdminDispatcherTests/testAdminUninstall`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/IPC/AdminProtocol.swift Sources/IrisKit/IPC/AdminDispatcher.swift Tests/IrisKitTests/AdminDispatcherTests.swift
git commit -m "feat(ipc): RPC admin.uninstall (Keychain-only, value-free, idempotent)"
```

---

## Task 4 : `MCPPatcher.unwrap(path:)` (extraction + refactor CLI)

**Files:**
- Modify: `Sources/IrisKit/MCPConfig/MCPPatcher.swift`
- Modify: `Sources/iris/Commands/MCPCommands.swift:366-408` (`Unwrap.run`)
- Test: `Tests/IrisKitTests/MCPConfig/MCPPatcherTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/IrisKitTests/MCPConfig/MCPPatcherTests.swift`:

```swift
func testUnwrapRestoresFromBackupAndRemovesIt() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-unwrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent(".mcp.json")
    let backup = dir.appendingPathComponent(".mcp.json.iris.bak")
    try Data(#"{"original":true}"#.utf8).write(to: backup)
    try Data(#"{"patched":true}"#.utf8).write(to: file)

    try MCPPatcher.unwrap(path: file.path)

    let restored = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(restored.contains("original"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "backup is removed")
}

func testUnwrapThrowsWhenBackupMissing() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-unwrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent(".mcp.json")
    try Data("{}".utf8).write(to: file)
    XCTAssertThrowsError(try MCPPatcher.unwrap(path: file.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MCPPatcherTests/testUnwrap`
Expected: FAIL (compile error: `unwrap` undefined).

- [ ] **Step 3: Add `unwrap(path:)` to `MCPPatcher`**

In `Sources/IrisKit/MCPConfig/MCPPatcher.swift`, add an error type and the function in the `// MARK: - Public API` section:

```swift
public enum UnwrapError: Error, LocalizedError, Equatable {
    case noBackup(String)
    case invalidBackupJSON(String)
    public var errorDescription: String? {
        switch self {
        case .noBackup(let p): return "no backup found or readable at \(p)"
        case .invalidBackupJSON(let p): return "backup is not valid JSON: \(p)"
        }
    }
}

/// Restores `path` from its sibling `<path>.iris.bak`, then removes the backup.
/// Mirrors the previous CLI behaviour (atomic `replaceItemAt`). Validates that
/// the backup parses as JSON before clobbering the live file.
public static func unwrap(path: String) throws {
    let fileURL = URL(fileURLWithPath: path)
    let backupURL = fileURL.appendingPathExtension("iris.bak")
    guard let backupData = try? Data(contentsOf: backupURL) else {
        throw UnwrapError.noBackup(backupURL.path)
    }
    guard (try? JSONSerialization.jsonObject(with: backupData, options: [.allowFragments])) != nil
    else {
        throw UnwrapError.invalidBackupJSON(backupURL.path)
    }
    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: backupURL)
}
```

- [ ] **Step 4: Refactor `Unwrap.run` to call it**

Replace the body of `Unwrap.run()` (`Sources/iris/Commands/MCPCommands.swift`, the sanity-check + `replaceItemAt` block, lines ~371-396) with:

```swift
        mutating func run() async throws {
            let expanded = (path as NSString).expandingTildeInPath
            do {
                try MCPPatcher.unwrap(path: expanded)
            } catch let e as MCPPatcher.UnwrapError {
                FileHandle.standardError.write(Data("\(e.errorDescription ?? "\(e)")\n".utf8))
                throw ExitCode(IrisExitCode.logicError)
            } catch {
                FileHandle.standardError.write(Data("restore failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }

            if json {
                let dict: [String: Any] = ["ok": true, "restored": expanded]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                    let jsonString = String(data: data, encoding: .utf8)
                {
                    print(jsonString)
                }
            } else {
                print("restored \(expanded)")
            }
        }
```

> The registry hookup (`WrappedPathsRegistry.remove`) is added in Task 6, not here.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MCPPatcherTests/testUnwrap`
Then: `swift build` (confirms the CLI refactor compiles).
Expected: PASS + build OK.

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/MCPConfig/MCPPatcher.swift Sources/iris/Commands/MCPCommands.swift Tests/IrisKitTests/MCPConfig/MCPPatcherTests.swift
git commit -m "refactor(mcp): extraire MCPPatcher.unwrap réutilisable (CLI inchangée)"
```

---

## Task 5 : `WrappedPathsRegistry`

**Files:**
- Create: `Sources/IrisKit/MCPConfig/WrappedPathsRegistry.swift`
- Test: `Tests/IrisKitTests/MCPConfig/WrappedPathsRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/IrisKitTests/MCPConfig/WrappedPathsRegistryTests.swift`:

```swift
import XCTest
@testable import IrisKit

final class WrappedPathsRegistryTests: XCTestCase {
    private func makeManifestURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-reg-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("wrapped-paths.json")
    }

    func testAddDedupesAndListReturnsInsertionOrder() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        try reg.add("/a/.mcp.json")
        try reg.add("/b/.mcp.json")
        try reg.add("/a/.mcp.json")  // duplicate
        XCTAssertEqual(try reg.list(), ["/a/.mcp.json", "/b/.mcp.json"])
    }

    func testRemove() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        try reg.add("/a/.mcp.json")
        try reg.add("/b/.mcp.json")
        try reg.remove("/a/.mcp.json")
        XCTAssertEqual(try reg.list(), ["/b/.mcp.json"])
    }

    func testListIsEmptyWhenManifestAbsent() throws {
        let reg = WrappedPathsRegistry(manifestURL: makeManifestURL())
        XCTAssertEqual(try reg.list(), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WrappedPathsRegistryTests`
Expected: FAIL (compile error: `WrappedPathsRegistry` undefined).

- [ ] **Step 3: Implement**

Create `Sources/IrisKit/MCPConfig/WrappedPathsRegistry.swift`:

```swift
import Foundation

/// Records the absolute paths of MCP config files that `iris mcp wrap` has
/// patched, so the uninstall flow can restore every one of them. The manifest
/// is a JSON array of absolute paths, deduplicated, insertion-ordered.
///
/// Lives at `~/Library/Application Support/iris/wrapped-paths.json` by default;
/// tests inject a temporary URL.
public struct WrappedPathsRegistry: Sendable {
    private let manifestURL: URL

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    /// Default location, alongside the daemon's other support files.
    public static func defaultManifestURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("iris", isDirectory: true)
            .appendingPathComponent("wrapped-paths.json")
    }

    public func list() throws -> [String] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public func add(_ path: String) throws {
        var paths = try list()
        guard !paths.contains(path) else { return }
        paths.append(path)
        try write(paths)
    }

    public func remove(_ path: String) throws {
        var paths = try list()
        paths.removeAll { $0 == path }
        try write(paths)
    }

    private func write(_ paths: [String]) throws {
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(paths).write(to: manifestURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WrappedPathsRegistryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/MCPConfig/WrappedPathsRegistry.swift Tests/IrisKitTests/MCPConfig/WrappedPathsRegistryTests.swift
git commit -m "feat(mcp): WrappedPathsRegistry (manifeste des configs MCP wrappées)"
```

---

## Task 6 : Brancher le registre dans `mcp wrap` / `mcp unwrap`

**Files:**
- Modify: `Sources/iris/Commands/MCPCommands.swift` (`Wrap.run` after successful write; `Unwrap.run` after restore; `runOneCycle` for `--watch`)
- Test: `Tests/IntegrationTests/MCPWrapFlowTests.swift`

- [ ] **Step 1: Write the failing test**

Read the top of `Tests/IntegrationTests/MCPWrapFlowTests.swift` to reuse its existing daemon-spawn + temp-file scaffolding. Add a test that wraps a real temp `.mcp.json`, asserts the manifest now lists its path, then unwraps and asserts the path is gone. Because the CLI resolves the manifest via `WrappedPathsRegistry.defaultManifestURL()` (real App Support), inject an override: add an env var `IRIS_WRAPPED_PATHS_MANIFEST` read by the CLI, pointed at a temp file in the test.

```swift
func testWrapRecordsPathAndUnwrapRemovesIt() async throws {
    // ... existing scaffolding: start ephemeral daemon, write a temp .mcp.json
    // with an `mcpServers` entry that will be patched ...
    let manifest = tmpDir.appendingPathComponent("wrapped-paths.json")
    setenv("IRIS_WRAPPED_PATHS_MANIFEST", manifest.path, 1)
    defer { unsetenv("IRIS_WRAPPED_PATHS_MANIFEST") }

    try await runIris(["mcp", "wrap", mcpFile.path])
    let afterWrap = WrappedPathsRegistry(manifestURL: manifest)
    XCTAssertEqual(try afterWrap.list(), [mcpFile.path])

    try await runIris(["mcp", "unwrap", mcpFile.path])
    XCTAssertEqual(try afterWrap.list(), [])
}
```

> Adapt `runIris(...)` / daemon spawn to the helpers actually used in this file. If the file spawns the CLI as a subprocess, set the env var on the child process environment instead of `setenv`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MCPWrapFlowTests/testWrapRecordsPathAndUnwrapRemovesIt`
Expected: FAIL (manifest stays empty — registry not wired).

- [ ] **Step 3: Add a manifest-resolving helper in `MCPCommands.swift`**

At file scope in `Sources/iris/Commands/MCPCommands.swift`, add:

```swift
/// Resolves the wrapped-paths registry, honouring an env override used by
/// integration tests so they never touch the real App Support manifest.
private func wrappedPathsRegistry() throws -> WrappedPathsRegistry {
    if let override = ProcessInfo.processInfo.environment["IRIS_WRAPPED_PATHS_MANIFEST"] {
        return WrappedPathsRegistry(manifestURL: URL(fileURLWithPath: override))
    }
    return WrappedPathsRegistry(manifestURL: try WrappedPathsRegistry.defaultManifestURL())
}
```

- [ ] **Step 4: Record on wrap**

In `Wrap.run()`, immediately after the successful `patchedData.write(to: fileURL, options: .atomic)` and before `emitOutcome(...)` (around line 160), add:

```swift
            try? wrappedPathsRegistry().add(expanded)
```

In `runOneCycle(...)` (the `--watch` path), after the successful `patchedData.write(...)` (around line 340), add the same line:

```swift
            try? wrappedPathsRegistry().add(fileURL.path)
```

> `try?` (best-effort): a registry write failure must not fail the wrap itself — the file is already patched.

- [ ] **Step 5: De-record on unwrap**

In `Unwrap.run()`, after the successful `MCPPatcher.unwrap(path: expanded)` call, add:

```swift
            try? wrappedPathsRegistry().remove(expanded)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter MCPWrapFlowTests/testWrapRecordsPathAndUnwrapRemovesIt`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/Commands/MCPCommands.swift Tests/IntegrationTests/MCPWrapFlowTests.swift
git commit -m "feat(mcp): wrap/unwrap tiennent à jour le registre des chemins wrappés"
```

---

## Task 7 : Seam `MCPUnwrapping` + impl prod + fake

**Files:**
- Create: `Sources/IrisAppCore/Protocols/MCPUnwrapping.swift`
- Create: `Tests/IrisAppCoreTests/Mocks/FakeMCPUnwrapper.swift`

- [ ] **Step 1: Implement the seam + production type**

Create `Sources/IrisAppCore/Protocols/MCPUnwrapping.swift`:

```swift
import Foundation
import IrisKit

/// Result of restoring all wrapped MCP config files.
public struct MCPUnwrapReport: Sendable, Equatable {
    /// Paths successfully restored.
    public var restored: [String]
    /// Paths that were listed but could not be restored (missing file/backup).
    public var skipped: [String]
    public init(restored: [String] = [], skipped: [String] = []) {
        self.restored = restored
        self.skipped = skipped
    }
}

/// Seam over the wrapped-paths registry + `MCPPatcher.unwrap`. Production:
/// `SystemMCPUnwrapper`. Tests: `FakeMCPUnwrapper`. Mirrors the seam pattern of
/// `CATrustInstalling` / `ShellConfiguring`.
public protocol MCPUnwrapping: Sendable {
    func unwrapAll() throws -> MCPUnwrapReport
}

public struct SystemMCPUnwrapper: MCPUnwrapping {
    private let registry: WrappedPathsRegistry

    public init(registry: WrappedPathsRegistry? = nil) throws {
        if let registry {
            self.registry = registry
        } else {
            self.registry = WrappedPathsRegistry(manifestURL: try WrappedPathsRegistry.defaultManifestURL())
        }
    }

    public func unwrapAll() throws -> MCPUnwrapReport {
        var report = MCPUnwrapReport()
        for path in try registry.list() {
            do {
                try MCPPatcher.unwrap(path: path)
                try? registry.remove(path)
                report.restored.append(path)
            } catch {
                // Stale entry (file or backup gone) — skip, never fatal.
                try? registry.remove(path)
                report.skipped.append(path)
            }
        }
        return report
    }
}
```

> Note: `WrappedPathsRegistry.init(manifestURL:)` is non-throwing; only `defaultManifestURL()` throws, which is why `SystemMCPUnwrapper.init` is `throws` (and Task 9 wraps it in `try?`).

- [ ] **Step 2: Create the fake**

Create `Tests/IrisAppCoreTests/Mocks/FakeMCPUnwrapper.swift`:

```swift
import Foundation
@testable import IrisAppCore

final class FakeMCPUnwrapper: MCPUnwrapping, @unchecked Sendable {
    var stubReport = MCPUnwrapReport()
    var shouldThrow: Error?
    private(set) var called = false

    func unwrapAll() throws -> MCPUnwrapReport {
        called = true
        if let e = shouldThrow { throw e }
        return stubReport
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build && swift test --filter WrappedPathsRegistryTests`
Expected: build OK (no behaviour change yet; the seam is consumed in Task 9).

- [ ] **Step 4: Commit**

```bash
git add Sources/IrisAppCore/Protocols/MCPUnwrapping.swift Tests/IrisAppCoreTests/Mocks/FakeMCPUnwrapper.swift
git commit -m "feat(app): seam MCPUnwrapping (registre → MCPPatcher.unwrap)"
```

---

## Task 8 : `AdminCalling.uninstall(deleteSecrets:)`

**Files:**
- Modify: `Sources/IrisAppCore/Protocols/AdminCalling.swift`
- Modify: `Sources/IrisAppCore/Protocols/IrisKitConformances.swift`
- Modify: `Tests/IrisAppCoreTests/Mocks/FakeAdminCalling.swift`

- [ ] **Step 1: Add to the protocol**

In `Sources/IrisAppCore/Protocols/AdminCalling.swift`, add after `caExportPath()`:

```swift
    /// Daemon-side uninstall: removes the CA private key always, and the user's
    /// secrets only when `deleteSecrets` is true. Must run while the daemon is
    /// alive (ACL 8b) — call before unregistering the service.
    func uninstall(deleteSecrets: Bool) async throws -> AdminUninstallResult
```

- [ ] **Step 2: Conform in `IrisKitConformances.swift`**

In the `extension AdminClient: AdminCalling`, add:

```swift
    public func uninstall(deleteSecrets: Bool) async throws -> AdminUninstallResult {
        try await call(
            .adminUninstall,
            params: AdminUninstallParams(deleteSecrets: deleteSecrets),
            returning: AdminUninstallResult.self
        )
    }
```

- [ ] **Step 3: Add to the fake**

In `Tests/IrisAppCoreTests/Mocks/FakeAdminCalling.swift`, add a stub field near the other `stub*` fields:

```swift
    var stubUninstallResult = AdminUninstallResult(caKeyDeleted: true, secretsDeleted: 0)
    var uninstallDeleteSecretsArg: Bool?
```

and add the method (mirroring the other methods that append to `calls`):

```swift
    func uninstall(deleteSecrets: Bool) async throws -> AdminUninstallResult {
        calls.append("uninstall")
        uninstallDeleteSecretsArg = deleteSecrets
        if let e = shouldThrow { throw e }
        return stubUninstallResult
    }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: build OK (FakeAdminCalling now satisfies the protocol again).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisAppCore/Protocols/AdminCalling.swift Sources/IrisAppCore/Protocols/IrisKitConformances.swift Tests/IrisAppCoreTests/Mocks/FakeAdminCalling.swift
git commit -m "feat(app): AdminCalling.uninstall(deleteSecrets:) + conformance + fake"
```

---

## Task 9 : `AppModel.uninstall(...)` + `UninstallReport` (orchestration)

**Files:**
- Modify: `Sources/IrisAppCore/AppModel.swift`
- Test: `Tests/IrisAppCoreTests/AppModelUninstallTests.swift` (create)

The orchestration runs the strict order (I1: RPC before unregister), records each attempted step in order, and aggregates errors instead of aborting on the first failure.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IrisAppCoreTests/AppModelUninstallTests.swift`. Reuse the existing fakes (`FakeAdminCalling`, `FakeCATrustInstaller`, `FakeShellConfigurator`, `FakeAutoStartService`) — read `AppModelShellTests.swift` / `AutoStartTests.swift` / `AppModelCRUDTests.swift` to confirm their exact type names and initializers, and adapt below if they differ.

```swift
import XCTest
@testable import IrisAppCore

@MainActor
final class AppModelUninstallTests: XCTestCase {
    private func makeModel(
        ca: FakeCATrustInstaller = FakeCATrustInstaller(),
        shell: FakeShellConfigurator = FakeShellConfigurator(),
        autoStart: FakeAutoStartService = FakeAutoStartService(),
        mcp: FakeMCPUnwrapper = FakeMCPUnwrapper()
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "io.iris.app.tests.\(UUID().uuidString)")!,
            caInstaller: ca,
            shellConfigurator: shell,
            autoStart: autoStart,
            mcpUnwrapper: mcp
        )
    }

    func testUninstallRunsRPCBeforeUnregister() async {
        let admin = FakeAdminCalling()
        let autoStart = FakeAutoStartService()
        let model = makeModel(autoStart: autoStart)
        let report = await model.uninstall(deleteSecrets: false, via: admin)

        // I1 — the RPC step precedes both unregister steps.
        let rpcIdx = report.steps.firstIndex(of: .rpc)
        let unregIdx = report.steps.firstIndex(of: .unregisterDaemon)
        XCTAssertNotNil(rpcIdx); XCTAssertNotNil(unregIdx)
        XCTAssertLessThan(rpcIdx!, unregIdx!)
        XCTAssertTrue(admin.calls.contains("uninstall"))
        XCTAssertEqual(admin.uninstallDeleteSecretsArg, false)
    }

    func testUninstallPropagatesDeleteSecretsFlag() async {
        let admin = FakeAdminCalling()
        let model = makeModel()
        _ = await model.uninstall(deleteSecrets: true, via: admin)
        XCTAssertEqual(admin.uninstallDeleteSecretsArg, true)
    }

    func testUninstallAggregatesErrorsAndContinues() async {
        struct Boom: Error {}
        let admin = FakeAdminCalling()
        let ca = FakeCATrustInstaller()
        ca.shouldThrow = Boom()  // cert removal fails (e.g. admin prompt cancelled)
        let autoStart = FakeAutoStartService()
        let model = makeModel(ca: ca, autoStart: autoStart)

        let report = await model.uninstall(deleteSecrets: false, via: admin)

        XCTAssertTrue(report.failures.contains { $0.step == .ca })
        // Despite the cert failure, later steps still ran.
        XCTAssertTrue(report.steps.contains(.unregisterDaemon))
        XCTAssertTrue(report.steps.contains(.shell))
    }
}
```

> If `FakeCATrustInstaller` / `FakeAutoStartService` expose error injection under a different field name than `shouldThrow`, adapt. If `AppModel.init` doesn't yet accept `mcpUnwrapper`, that's added in Step 3.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppModelUninstallTests`
Expected: FAIL (compile error: `uninstall`/`mcpUnwrapper`/`UninstallReport` undefined).

- [ ] **Step 3: Add the seam to `AppModel` init**

In `Sources/IrisAppCore/AppModel.swift`, add a stored property next to the other seams (`caInstaller`, `shellConfigurator`, `autoStart`):

```swift
    private let mcpUnwrapper: MCPUnwrapping
```

and add a parameter to `init(...)` with a default. Because `SystemMCPUnwrapper.init` throws, the default must tolerate failure (fall back to a no-op so a broken App Support never blocks app launch):

```swift
        mcpUnwrapper: MCPUnwrapping = (try? SystemMCPUnwrapper()) ?? NoopMCPUnwrapper()
```

assign it in the body: `self.mcpUnwrapper = mcpUnwrapper`.

Add the no-op fallback at file scope (or near the seam usage):

```swift
/// Used when the wrapped-paths manifest can't be located at launch; the
/// uninstall flow then simply restores nothing rather than crashing.
private struct NoopMCPUnwrapper: MCPUnwrapping {
    func unwrapAll() throws -> MCPUnwrapReport { MCPUnwrapReport() }
}
```

- [ ] **Step 4: Add `UninstallReport` + `uninstall(...)`**

At file scope in `AppModel.swift` (above the class, like other public model types):

```swift
public struct UninstallReport: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case rpc, ca, mcp, shell, unregisterDaemon, unregisterApp
    }
    public struct Failure: Sendable, Equatable {
        public let step: Step
        public let message: String
    }
    /// Steps actually attempted, in execution order (I1 lives here).
    public var steps: [Step] = []
    public var failures: [Failure] = []
    public var caKeyDeleted = false
    public var secretsDeleted = 0
    public var mcpRestored: [String] = []
}
```

Add the method in `AppModel` (after `uninstallCA(via:)`). It never throws — it returns a report:

```swift
    /// Orchestrates the in-app uninstall. Strict order (I1): the daemon RPC runs
    /// first, while irisd is alive and holds the Keychain ACL; unregister last,
    /// which stops the daemon and releases the bundle lock. Each step is isolated:
    /// a failure is recorded and the next step still runs (Rule 12 — fail loud).
    public func uninstall(deleteSecrets: Bool, via admin: AdminCalling) async -> UninstallReport {
        var report = UninstallReport()

        // 1. Keychain via daemon (must precede unregister).
        report.steps.append(.rpc)
        do {
            let r = try await admin.uninstall(deleteSecrets: deleteSecrets)
            report.caKeyDeleted = r.caKeyDeleted
            report.secretsDeleted = r.secretsDeleted
        } catch {
            report.failures.append(.init(step: .rpc, message: "\(error)"))
        }

        // 2. Trust store (admin prompt).
        report.steps.append(.ca)
        do {
            let path = try await admin.caExportPath()
            let installer = caInstaller
            try await Task.detached { try installer.uninstall(pemPath: path) }.value
        } catch {
            report.failures.append(.init(step: .ca, message: "\(error)"))
        }

        // 3. MCP unwrap.
        report.steps.append(.mcp)
        do {
            let unwrapper = mcpUnwrapper
            let r = try await Task.detached { try unwrapper.unwrapAll() }.value
            report.mcpRestored = r.restored
        } catch {
            report.failures.append(.init(step: .mcp, message: "\(error)"))
        }

        // 4. Shell block.
        report.steps.append(.shell)
        do {
            let cfg = shellConfigurator
            try await Task.detached { try cfg.uninstall() }.value
        } catch {
            report.failures.append(.init(step: .shell, message: "\(error)"))
        }

        // 5. Auto-start (last — releases the bundle lock).
        report.steps.append(.unregisterDaemon)
        do {
            let service = autoStart
            try await Task.detached { try service.unregister(.daemon) }.value
        } catch {
            report.failures.append(.init(step: .unregisterDaemon, message: "\(error)"))
        }
        report.steps.append(.unregisterApp)
        do {
            let service = autoStart
            try await Task.detached { try service.unregister(.app) }.value
        } catch {
            report.failures.append(.init(step: .unregisterApp, message: "\(error)"))
        }

        return report
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AppModelUninstallTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all green (no regressions in AppModel init callers — the new param has a default).

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisAppCore/AppModel.swift Tests/IrisAppCoreTests/AppModelUninstallTests.swift
git commit -m "feat(app): AppModel.uninstall orchestration (ordre strict I1, erreurs agrégées)"
```

---

## Task 10 : Section « Quit & Uninstall » dans `SettingsTab`

No unit test (SwiftUI view). Verified by `xcodebuild` (compile) + smoke. The cible IrisApp uses a synchronized file group → no pbxproj edit needed.

**Files:**
- Modify: `IrisApp/IrisApp/SettingsTab.swift`

- [ ] **Step 1: Add state for the confirm dialog + final alert**

In `SettingsTab`, add `@State` fields next to `errorText`/`statusText`:

```swift
    @State private var showUninstallConfirm = false
    @State private var deleteSecretsOnUninstall = false
    @State private var uninstallSummary: String?
    @State private var showUninstallDone = false
```

- [ ] **Step 2: Add the section to the body**

In `body`, add `uninstallBox()` after `autoStartBox()` (before `connectionBox(cfg)`):

```swift
                    autoStartBox()
                    uninstallBox()
                    connectionBox(cfg)
```

- [ ] **Step 3: Add the section view + the action**

Add this `@ViewBuilder` after `autoStartBox()` and its action helper after `toggleAutoStart`:

```swift
    @ViewBuilder private func uninstallBox() -> some View {
        GroupBox("Uninstall") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stops irisd, removes auto-start, the CA certificate and the terminal configuration.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit & Uninstall…", role: .destructive) { showUninstallConfirm = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog(
            "Uninstall IRIS?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall (keep my secrets)", role: .destructive) {
                deleteSecretsOnUninstall = false
                runUninstall()
            }
            Button("Uninstall and delete my secrets", role: .destructive) {
                deleteSecretsOnUninstall = true
                runUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your secrets stay in the Keychain unless you choose to delete them.")
        }
        .alert("Almost done", isPresented: $showUninstallDone) {
            Button("Reveal uninstall.sh") { revealUninstallScript(); quitApp() }
            Button("Quit", role: .cancel) { quitApp() }
        } message: {
            Text(uninstallSummary ?? "")
        }
    }

    private func runUninstall() {
        Task {
            let report = await model.uninstall(deleteSecrets: deleteSecretsOnUninstall, via: admin)
            uninstallSummary = Self.summarize(report)
            showUninstallDone = true
        }
    }

    private static func summarize(_ r: UninstallReport) -> String {
        var lines = [String]()
        lines.append("CA key removed: \(r.caKeyDeleted ? "yes" : "no")")
        lines.append("Secrets deleted: \(r.secretsDeleted)")
        if !r.mcpRestored.isEmpty { lines.append("MCP configs restored: \(r.mcpRestored.count)") }
        if !r.failures.isEmpty {
            lines.append("Could not complete: " + r.failures.map { "\($0.step)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("To finish: the CLI and the app need your password. Run uninstall.sh (in the Finder), or drag Iris to the Trash.")
        return lines.joined(separator: "\n")
    }

    private func revealUninstallScript() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let script = support?
            .appendingPathComponent("iris", isDirectory: true)
            .appendingPathComponent("uninstall.sh")
        if let script, FileManager.default.fileExists(atPath: script.path) {
            NSWorkspace.shared.activateFileViewerSelecting([script])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
```

- [ ] **Step 4: Build the app target**

Run: `xcodebuild -scheme IrisApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

> The compiler is the oracle here, not SourceKit. If `UninstallReport` isn't found, confirm `import IrisAppCore` is present at the top of `SettingsTab.swift` (it is, per current file).

- [ ] **Step 5: Commit**

```bash
git add IrisApp/IrisApp/SettingsTab.swift
git commit -m "feat(app): section « Quit & Uninstall » (confirm + secrets opt-in + reveal script)"
```

---

## Task 11 : Script de secours `packaging/scripts/uninstall.sh`

**Files:**
- Create: `packaging/scripts/uninstall.sh`

- [ ] **Step 1: Write the script**

Create `packaging/scripts/uninstall.sh`. Derived from `packaging/dev-uninstall.sh` but restricted to a clean install (no dev residue). Adds `--yes` (non-interactive except secrets) and `--delete-secrets`.

```bash
#!/bin/bash
# IRIS uninstall.sh — désinstallation propre côté utilisateur.
#
# Déposé dans ~/Library/Application Support/iris/ par le postinstall (survit au
# drag-to-trash) et versionné dans packaging/scripts/. Couvre le paquet « root »
# (sudo) et le cas « app déjà jetée ». Le bouton in-app fait le reste sans mot
# de passe ; ce script termine ce qui exige sudo.
#
# Usage : bash uninstall.sh [--yes] [--delete-secrets]
#   --yes             non-interactif (sauf les secrets, toujours opt-in explicite)
#   --delete-secrets  supprime aussi les secrets du trousseau (sinon conservés)
set -u

YES=0; DELETE_SECRETS=0
for arg in "$@"; do
    case "$arg" in
        --yes) YES=1 ;;
        --delete-secrets) DELETE_SECRETS=1 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
SUP="$HOME/Library/Application Support/iris"
MANIFEST="$SUP/wrapped-paths.json"

confirm() {
    [ "$YES" = 1 ] && return 0
    printf '%s' "${YEL}» $1 [y/N] ${RST}"; read -r a
    [ "$a" = y ] || [ "$a" = Y ] || [ "$a" = yes ]
}
section() { printf '\n%s\n' "${BOLD}=== $1 ===${RST}"; }
ok()      { printf '%s\n' "${GRN}  $1${RST}"; }

# 1. Daemon (sinon le bundle reste verrouillé).
section "1. Arrêt du daemon (launchd)"
if launchctl print "gui/$(id -u)/io.iris.daemon" >/dev/null 2>&1; then
    if confirm "Arrêter irisd (launchctl bootout) ?"; then
        launchctl bootout "gui/$(id -u)/io.iris.daemon" 2>/dev/null || true
        ok "arrêté."
    fi
else
    ok "non actif."
fi

# 2. MCP unwrap (avant de retirer App Support + le CLI).
section "2. Restauration des configs MCP wrappées"
if [ -f "$MANIFEST" ]; then
    i=0
    while p="$(plutil -extract "$i" raw -o - "$MANIFEST" 2>/dev/null)"; do
        bak="$p.iris.bak"
        if [ -f "$bak" ]; then
            if confirm "Restaurer $p depuis son backup ?"; then
                cp "$bak" "$p" && rm -f "$bak" && ok "restauré: $p"
            fi
        else
            printf '%s\n' "${DIM}  backup absent (déjà restauré ?): $p${RST}"
        fi
        i=$((i+1))
    done
    [ "$i" = 0 ] && ok "aucune config wrappée listée."
else
    ok "aucun registre MCP."
fi

# 3. Bundle /Applications/Iris.app (root:wheel).
section "3. Application /Applications/Iris.app"
if [ -d /Applications/Iris.app ]; then
    if confirm "Supprimer /Applications/Iris.app (sudo) ?"; then
        sudo rm -rf /Applications/Iris.app && ok "supprimée."
    fi
else
    ok "absente (déjà jetée ?)."
fi

# 4. CLI /usr/local/bin/iris (root:wheel).
section "4. CLI /usr/local/bin/iris"
if [ -e /usr/local/bin/iris ]; then
    if confirm "Supprimer /usr/local/bin/iris (sudo) ?"; then
        sudo rm -f /usr/local/bin/iris && ok "supprimé."
    fi
else
    ok "absent."
fi

# 5. Reçus d'installation.
section "5. Reçus d'installation (pkgutil)"
pkgs="$(pkgutil --pkgs 2>/dev/null | grep -E 'io\.iris\.(app|cli)' || true)"
if [ -n "$pkgs" ]; then
    printf '%s\n' "$pkgs"
    if confirm "Oublier ces reçus (sudo pkgutil --forget) ?"; then
        while IFS= read -r p; do [ -n "$p" ] && sudo pkgutil --forget "$p"; done <<< "$pkgs"
    fi
else
    ok "aucun reçu io.iris.*."
fi

# 6. Certificat(s) CA dans le trust store (sans panneau).
section "6. Certificat(s) « IRIS local CA » (trust store)"
shas="$(security find-certificate -a -c "IRIS local CA" -Z "$LOGIN_KC" 2>/dev/null | awk '/SHA-1 hash:/{print $3}' || true)"
if [ -n "$shas" ]; then
    printf 'SHA-1 trouvés:\n%s\n' "$shas"
    if confirm "Supprimer ces certificats (delete-certificate -Z) ?"; then
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            security delete-certificate -Z "$sha" "$LOGIN_KC" 2>/dev/null && printf '  supprimé: %s\n' "$sha"
        done <<< "$shas"
    fi
else
    ok "aucun cert IRIS local CA."
fi

# 7. Clé privée CA (prompt trousseau attendu : plus d'ACL daemon).
section "7. Clé privée CA (io.iris.ca)"
if security find-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1; then
    printf '%s\n' "${DIM}  Une autorisation trousseau peut s'afficher (le daemon n'est plus là pour l'ACL).${RST}"
    if confirm "Supprimer la clé privée CA ?"; then
        security delete-generic-password -s io.iris.ca -a privatekey >/dev/null 2>&1 && ok "supprimée."
    fi
else
    ok "absente."
fi

# 8. Secrets utilisateur — opt-in STRICT (§10).
section "8. Secrets utilisateur (io.iris.secret)  ⚠️ tes vraies clés API"
if [ "$DELETE_SECRETS" = 1 ] || { [ "$YES" = 0 ] && confirm "Supprimer TOUS les secrets io.iris.secret ?"; }; then
    n=0; while security delete-generic-password -s io.iris.secret >/dev/null 2>&1; do n=$((n+1)); done
    ok "$n secret(s) supprimé(s)."
else
    ok "conservés (utilise --delete-secrets pour les supprimer)."
fi

# 9. Bloc IRIS dans ~/.zshrc.
section "9. Bloc IRIS dans ~/.zshrc"
if grep -q '# >>> iris >>>' "$HOME/.zshrc" 2>/dev/null; then
    if confirm "Retirer le bloc iris de ~/.zshrc (backup créé) ?"; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.iris-bak.$(date +%s)"
        sed -i '' '/# >>> iris >>>/,/# <<< iris <<</d' "$HOME/.zshrc"
        ok "retiré."
    fi
else
    ok "aucun bloc iris."
fi

# 10. Fichiers de support — EN DERNIER (self-suppression, après lecture du registre).
section "10. Fichiers de support ~/Library/Application Support/iris"
if [ -d "$SUP" ]; then
    if confirm "Supprimer $SUP (y compris ce script) ?"; then
        rm -rf "$SUP" && ok "supprimé."
    fi
else
    ok "absent."
fi

printf '\n%s\n' "${BOLD}Désinstallation terminée.${RST}"
printf '%s\n' "${DIM}Pensez à retirer Iris dans Réglages Système → Général → Ouverture au démarrage.${RST}"
```

- [ ] **Step 2: Make it executable + syntax-check**

```bash
chmod +x packaging/scripts/uninstall.sh
bash -n packaging/scripts/uninstall.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add packaging/scripts/uninstall.sh
git commit -m "feat(packaging): uninstall.sh de secours (paquet root, MCP unwrap, secrets opt-in)"
```

---

## Task 12 : `postinstall` dépose le script + `bash -n` en CI

**Files:**
- Modify: `packaging/scripts/postinstall`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Deposit the script in App Support from postinstall**

In `packaging/scripts/postinstall`, inside the `if [ -n "$INSTALL_USER" ] ...` block, right after the `mkdir -p ".../iris"` line, add:

```bash
    # Temps 2 : déposer le script de désinstallation de secours dans App Support
    # (survit au drag-to-trash). Best-effort : un échec ne casse pas l'install.
    if [ -f "$(dirname "$0")/uninstall.sh" ]; then
        sudo -u "$INSTALL_USER" cp "$(dirname "$0")/uninstall.sh" \
            "$USER_HOME/Library/Application Support/iris/uninstall.sh" || true
        sudo -u "$INSTALL_USER" chmod +x \
            "$USER_HOME/Library/Application Support/iris/uninstall.sh" || true
    fi
```

> `postinstall` runs `set -euo pipefail`; the `|| true` on each command keeps a copy failure non-fatal (consistent with the existing `open --first-launch || true`).

- [ ] **Step 2: Add a syntax-check step to CI**

In `.github/workflows/ci.yml`, in the existing `build-test` job (after checkout, before/after the build step), add a step:

```yaml
      - name: Shell script syntax (uninstall.sh)
        run: bash -n packaging/scripts/uninstall.sh
```

> Read the current `ci.yml` to place this under the right job with the correct indentation. If a lint/format job is the more natural home, put it there.

- [ ] **Step 3: Verify locally**

```bash
bash -n packaging/scripts/postinstall && echo "postinstall OK"
```

Expected: `postinstall OK`.

- [ ] **Step 4: Commit**

```bash
git add packaging/scripts/postinstall .github/workflows/ci.yml
git commit -m "feat(packaging): postinstall dépose uninstall.sh + bash -n en CI"
```

---

## Task 13 : Documentation utilisateur

**Files:**
- Modify: `docs/user-guide.md`

- [ ] **Step 1: Add an "Uninstall" section**

Read `docs/user-guide.md` to match its heading style and find the right place (near the end / after the install section). Add a section covering both paths. Use the actual heading depth/format already in the file; content to convey:

```markdown
## Désinstaller

Deux chemins, selon que l'app est encore là ou non.

### Depuis l'app (recommandé)

Menu bar → onglet **Settings** → **Quit & Uninstall**. Une boîte de dialogue
propose de conserver ou de supprimer vos secrets (conservés par défaut). L'app :

- nettoie le trousseau (clé CA, et vos secrets si vous l'avez demandé) — sans
  aucune invite ;
- retire le certificat CA du trust store (une invite mot de passe) ;
- restaure les fichiers de configuration MCP que `iris mcp wrap` avait modifiés ;
- retire le bloc IRIS de votre `~/.zshrc` ;
- désenregistre le démarrage automatique ;
- ouvre le Finder et révèle `uninstall.sh`.

Le **CLI** (`/usr/local/bin/iris`) et l'**application** (`/Applications/Iris.app`)
appartiennent au système : ils exigent votre mot de passe. Pour les retirer,
lancez le script révélé dans le Finder.

### Avec le script (app déjà supprimée, ou pour finir)

```bash
bash "$HOME/Library/Application Support/iris/uninstall.sh"
```

Le script confirme chaque opération. Options : `--yes` (non-interactif, sauf les
secrets), `--delete-secrets` (supprime aussi vos secrets). Vos secrets ne sont
**jamais** supprimés sans demande explicite.

> Pensez à retirer Iris dans **Réglages Système → Général → Ouverture au
> démarrage** (ce réglage ne peut pas être retiré sans l'application).
```

- [ ] **Step 2: Verify the doc is coherent**

```bash
grep -n "Désinstaller" docs/user-guide.md
```

Expected: the new section is present.

- [ ] **Step 3: Commit**

```bash
git add docs/user-guide.md
git commit -m "docs(user-guide): section Désinstaller (bouton in-app + script de secours)"
```

---

## Final verification (before PR)

- [ ] **`swift build`** → succeeds.
- [ ] **`swift test`** → all green (expect ~+10 tests vs baseline 481).
- [ ] **`xcodebuild -scheme IrisApp -configuration Debug -destination 'platform=macOS' build`** → `BUILD SUCCEEDED`.
- [ ] **`swift-format lint --recursive Sources Tests`** (or the repo's configured invocation) → clean.
- [ ] **`bash -n packaging/scripts/uninstall.sh && bash -n packaging/scripts/postinstall`** → OK.
- [ ] Open the PR with the smoke checklist from spec §14 (boxes `- [ ]`), per CLAUDE.md §8.

## Spec coverage map

- Spec §5 (RPC) → Tasks 1, 2, 3.
- Spec §6 (bouton orchestration) → Tasks 8, 9, 10.
- Spec §7 (registre MCP + `MCPPatcher.unwrap`) → Tasks 4, 5, 6, 7.
- Spec §8 (script) → Task 11.
- Spec §9 (dépôt postinstall) → Task 12.
- Spec §10 invariants → I1 (Task 9 test), I2 (Tasks 3, 9, 11), I3 (Task 3 test), I4 (Tasks 1, 3 tests), I5 (Task 3 — daemon touches no files).
- Spec §11 (tests) → embedded in Tasks 1-9.
- Spec §12 (doc) → Task 13.
