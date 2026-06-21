# Plugins — Durcissements §14 #6-10 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durcir le registry/install des plugins (hors hot-path) sur les 5 points différés de P3 : cohérence FS↔config sous concurrence, validation d'id centralisée, copie verbatim (symlinks + caps), coût de re-hash, et validation de forme des capabilities.

**Architecture :** Tout le changement vit dans `IrisKit/Plugins` + le mapping d'erreur RPC. `PluginRegistry.install` passe à un schéma **staging → commit état → rename-into-place** (le rollback ne touche jamais un dossier committé). `directory(for:)` devient l'unique point throwing qui valide l'id. Un nouveau `PluginSourceValidator` refuse les symlinks et borne taille/nombre de fichiers avant toute copie. `PluginHasher` gagne une **signature stat-only** bon marché qui alimente un cache de hash dans le registry. `PluginCapabilities.validate()` rejette les formes invalides à l'install.

**Tech Stack :** Swift 5.9+, SwiftPM, XCTest, swift-crypto (SHA-256), `FileManager`/`realpath(3)`. Cible `-strict-concurrency=complete`.

**Décisions verrouillées (session 2026-06-21) :** #6 = staging + rename après commit ; #8 = refuser tout symlink (fail-closed) ; périmètre = les 5 (#6-10).

---

## File Structure

- **Modify** `Sources/IrisKit/Plugins/PluginManifest.swift` — `PluginCapabilities.validate()` (#10), nouveau cas `PluginError.unsafeSource`, appel de `capabilities.validate()` dans `PluginManifest.validate()`.
- **Modify** `Sources/IrisKit/Plugins/PluginHasher.swift` — extraire `regularFiles(in:)`, ajouter `signature(directory:)` (#9).
- **Create** `Sources/IrisKit/Plugins/PluginSourceValidator.swift` — refus symlink + caps (#8).
- **Modify** `Sources/IrisKit/Plugins/PluginRegistry.swift` — `directory(for:)` throwing (#7), cache de hash via `currentHash` (#9), `install` staging+rename (#6) + appel `PluginSourceValidator` (#8), `sourceLimits` injectable.
- **Modify** `Sources/IrisKit/Plugins/PluginHostManager.swift` — garde défensive `isSafePathComponent` avant dérivation de chemin (#7).
- **Modify** `Sources/IrisKit/IPC/JSONRPC.swift` — code RPC `pluginUnsafeSource` (-32035) (#8).
- **Modify** `Sources/IrisKit/IPC/AdminDispatcher.swift` — case `.unsafeSource` dans `mapPluginError` (#8).
- **Test** `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`, `PluginHasherTests.swift`, `PluginRegistryTests.swift`, nouveau `PluginSourceValidatorTests.swift`.

Commandes de vérification (oracles) :
- Tests ciblés : `swift test --filter <ClassName>`
- Build : `swift build`
- Lint CI exact : `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp`

---

## Task 1 — #10 : validation de forme des capabilities

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift` (struct `PluginCapabilities` ~249-263 ; `PluginManifest.validate()` ~65-87)
- Test: `Tests/IrisKitTests/Plugins/PluginManifestTests.swift`

- [ ] **Step 1 — Écrire les tests qui échouent**

Ajouter dans `PluginManifestTests.swift` :

```swift
func testValidateRejectsMalformedNetworkCapability() throws {
    let m = try decode(
        #"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ],
          "capabilities": { "network": ["api.example.com"], "filesystem": [] } }
        """#
    )
    XCTAssertThrowsError(try m.validate()) { error in
        guard case PluginError.invalidManifest = error else {
            return XCTFail("expected invalidManifest, got \(error)")
        }
    }
}

func testValidateRejectsNonNumericPort() throws {
    let m = try decode(
        #"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ],
          "capabilities": { "network": ["api.example.com:https"], "filesystem": [] } }
        """#
    )
    XCTAssertThrowsError(try m.validate()) { error in
        guard case PluginError.invalidManifest = error else {
            return XCTFail("expected invalidManifest, got \(error)")
        }
    }
}

func testValidateRejectsUnknownFilesystemCapability() throws {
    let m = try decode(
        #"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ],
          "capabilities": { "network": [], "filesystem": ["/etc"] } }
        """#
    )
    XCTAssertThrowsError(try m.validate()) { error in
        guard case PluginError.invalidManifest = error else {
            return XCTFail("expected invalidManifest, got \(error)")
        }
    }
}

func testValidateAcceptsWellFormedNetworkCapability() throws {
    let m = try decode(
        #"""
        { "id": "a.b", "name": "B", "version": "1", "api_version": 1, "executable": "run",
          "hooks": [ { "event": "on_request", "match": {} } ],
          "capabilities": { "network": ["api.example.com:443"], "filesystem": ["scratch"] } }
        """#
    )
    XCTAssertNoThrow(try m.validate())
}
```

- [ ] **Step 2 — Lancer, vérifier l'échec**

Run: `swift test --filter PluginManifestTests`
Expected: FAIL — `testValidateRejectsMalformedNetworkCapability` etc. (aucune validation de capability n'existe encore : `validate()` accepte tout).

- [ ] **Step 3 — Implémenter `PluginCapabilities.validate()`**

Dans `PluginManifest.swift`, ajouter à la struct `PluginCapabilities` (après `init(from:)`), avant le `}` de fermeture de la struct :

```swift
/// Filesystem capability values understood by the v1 sandbox. `scratch` =
/// a per-plugin private working dir; nothing else is granted by default.
static let knownFilesystemCapabilities: Set<String> = ["scratch"]

/// Structural validation of declared capabilities (design §5/§6). Rejects
/// garbage early (install time) rather than letting it reach the sandbox
/// profile. Note: SBPL injection is independently neutralised by
/// `PluginSandboxProfile.sbplString` escaping — this is defense in depth and
/// a fail-fast UX, not the injection boundary.
///
/// - `network`: each entry is `host:port`, host non-empty and free of
///   whitespace/control chars, port a decimal in 1...65535. (The SBPL
///   `(remote ip ...)` form is still PROVISIONAL — Seatbelt resolves no DNS —
///   so this validates shape, not runtime reachability. Cf. §6/§14.)
/// - `filesystem`: each entry must be a known capability (`scratch`).
func validate() throws {
    for endpoint in network {
        guard let colon = endpoint.lastIndex(of: ":") else {
            throw PluginError.invalidManifest("network capability must be host:port: \(endpoint)")
        }
        let host = String(endpoint[..<colon])
        let portString = String(endpoint[endpoint.index(after: colon)...])
        guard !host.isEmpty,
            !host.unicodeScalars.contains(where: { $0 == " " || CharacterSet.controlCharacters.contains($0) })
        else {
            throw PluginError.invalidManifest("invalid network host: \(endpoint)")
        }
        guard let port = Int(portString), (1...65535).contains(port) else {
            throw PluginError.invalidManifest("invalid network port: \(endpoint)")
        }
    }
    for entry in filesystem where !Self.knownFilesystemCapabilities.contains(entry) {
        throw PluginError.invalidManifest("unknown filesystem capability: \(entry)")
    }
}
```

Puis dans `PluginManifest.validate()`, avant le `}` final (après la boucle `for hook in hooks`) :

```swift
try capabilities.validate()
```

- [ ] **Step 4 — Lancer, vérifier le passage**

Run: `swift test --filter PluginManifestTests`
Expected: PASS (tous, anciens + nouveaux).

- [ ] **Step 5 — Commit**

```bash
git add Sources/IrisKit/Plugins/PluginManifest.swift Tests/IrisKitTests/Plugins/PluginManifestTests.swift
git commit -m "feat(plugins): valider la forme des capabilities (durcissement §14 #10)"
```

---

## Task 2 — #7 : validation d'id centralisée dans `directory(for:)`

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRegistry.swift` (`directory(for:)` ~22-24 ; call sites `loadManifest`/`view`/`install`/`enable`/`remove`)
- Modify: `Sources/IrisKit/Plugins/PluginHostManager.swift` (`startHost` ~130-135)
- Test: `Tests/IrisKitTests/Plugins/PluginRegistryTests.swift`

- [ ] **Step 1 — Écrire le test qui échoue**

Ajouter dans `PluginRegistryTests.swift` :

```swift
func testRemoveRejectsUnsafeIdAsUnknown() async throws {
    // A path-traversing id reaches no filesystem operation: it isn't in the
    // state array, so it surfaces unknownPlugin (uniform with enable), never
    // a path derived from the untrusted id.
    let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
    await assertThrowsAsyncError(try await reg.remove(id: "../../etc")) { error in
        XCTAssertEqual(error as? PluginError, .unknownPlugin("../../etc"))
    }
}
```

(Note : `testEnableRejectsUnsafeId` couvre déjà `enable`. Ce test ancre le comportement uniforme après centralisation et garde une régression contre un futur ordre d'opérations qui dériverait un chemin avant le check d'appartenance.)

- [ ] **Step 2 — Lancer, vérifier l'échec ou le passage**

Run: `swift test --filter PluginRegistryTests/testRemoveRejectsUnsafeIdAsUnknown`
Expected: PASS aujourd'hui (remove vérifie l'appartenance avant `directory(for:)`). Le test verrouille l'invariant ; il reste vert après le changement throwing. C'est une garde de non-régression, pas un test rouge-puis-vert (acceptable : la tâche durcit une signature interne).

- [ ] **Step 3 — Rendre `directory(for:)` throwing + validant**

Dans `PluginRegistry.swift`, remplacer :

```swift
private func directory(for id: String) -> URL {
    pluginsDirectory.appendingPathComponent(id, isDirectory: true)
}
```

par :

```swift
/// Single point where a filesystem path is derived from a plugin id. Validates
/// the id as a safe, non-traversing path component (#7) — every other method
/// that touches a per-plugin directory routes through here, so an unsafe id can
/// never reach `FileManager`. Installed ids were already validated at install
/// (manifest.validate), so this only ever throws for an id injected directly
/// into a public call for a plugin that isn't installed — and those callers
/// reject it as `unknownPlugin` first.
private func directory(for id: String) throws -> URL {
    guard PluginManifest.isSafePathComponent(id) else {
        throw PluginError.invalidManifest("invalid id: \(id)")
    }
    return pluginsDirectory.appendingPathComponent(id, isDirectory: true)
}
```

Puis ajouter `try` aux 5 call sites :
- `loadManifest` : `let url = try directory(for: id).appendingPathComponent("plugin.json")`
- `view` : `let currentHash = try PluginHasher.hash(directory: directory(for: entry.id))` → adapter (devient `try directory(...)` ; sera retouché en Task 4 pour le cache). Et `let manifest = try loadManifest(id: entry.id)` reste.
- `install` : `let dest = try directory(for: manifest.id)` (sera déplacé en Task 5).
- `enable` : `let currentHash = try PluginHasher.hash(directory: directory(for: id))`.
- `remove` : `try fm.removeItem(at: directory(for: id))` → `try fm.removeItem(at: try directory(for: id))`.

- [ ] **Step 4 — Garde défensive dans le manager (#7)**

Dans `PluginHostManager.startHost(for:)`, juste après `let id = plugin.manifest.id`, insérer :

```swift
// Defense in depth (design §14 #7): the runtime derives the executable and
// scratch paths from the id. Installed ids are validated at install, but never
// build a filesystem path from an id that isn't a safe component.
guard PluginManifest.isSafePathComponent(id) else {
    logger.error("plugin id is not a safe path component; refusing to launch", metadata: ["id": "\(id)"])
    return
}
```

- [ ] **Step 5 — Build + tests**

Run: `swift build` puis `swift test --filter PluginRegistryTests`
Expected: build OK, tests PASS.

- [ ] **Step 6 — Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRegistry.swift Sources/IrisKit/Plugins/PluginHostManager.swift Tests/IrisKitTests/Plugins/PluginRegistryTests.swift
git commit -m "feat(plugins): centraliser la validation d'id dans directory(for:) (durcissement §14 #7)"
```

---

## Task 3 — #9 : signature stat-only + cache de hash

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginHasher.swift`
- Modify: `Sources/IrisKit/Plugins/PluginRegistry.swift` (`view`, `enable`, `remove`)
- Test: `Tests/IrisKitTests/Plugins/PluginHasherTests.swift`, `PluginRegistryTests.swift`

- [ ] **Step 1 — Écrire les tests qui échouent**

Dans `PluginHasherTests.swift` :

```swift
func testSignatureStableForUnchangedTree() throws {
    let dir = try makeTree(["a.txt": "hello", "sub/b.txt": "world"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let s1 = try PluginHasher.signature(directory: dir)
    let s2 = try PluginHasher.signature(directory: dir)
    XCTAssertEqual(s1, s2)
}

func testSignatureChangesWhenContentSizeChanges() throws {
    let dir = try makeTree(["a.txt": "hello"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = try PluginHasher.signature(directory: dir)
    try "hello world".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let after = try PluginHasher.signature(directory: dir)
    XCTAssertNotEqual(before, after)
}

func testSignatureChangesWhenFileAdded() throws {
    let dir = try makeTree(["a.txt": "hello"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = try PluginHasher.signature(directory: dir)
    try "x".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
    let after = try PluginHasher.signature(directory: dir)
    XCTAssertNotEqual(before, after)
}
```

Ajouter le helper `makeTree` en bas de `PluginHasherTests.swift` (s'il n'existe pas déjà — vérifier le fichier d'abord) :

```swift
private func makeTree(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
    for (rel, contents) in files {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}
```

- [ ] **Step 2 — Lancer, vérifier l'échec**

Run: `swift test --filter PluginHasherTests`
Expected: FAIL — `PluginHasher.signature` n'existe pas (erreur de compilation des nouveaux tests).

- [ ] **Step 3 — Refactorer `PluginHasher` + ajouter `signature`**

Remplacer le corps de `PluginHasher` par (le helper `lengthPrefixed` reste inchangé) :

```swift
public static func hash(directory: URL) throws -> String {
    let files = try regularFiles(in: directory)
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

/// Cheap stat-only fingerprint of the tree: the sorted (relative path, mtime,
/// size) of every regular file — the SAME set `hash` folds in. An unchanged
/// signature ⇒ unchanged content, so the registry can skip the (far costlier)
/// content `hash`. Detects add/remove/rename (path set changes) and in-place
/// edits (size or mtime change). Residual blind spot: an edit preserving BOTH
/// byte count AND nanosecond mtime — only reachable by someone with write
/// access to the 0600 user-owned plugins dir, who has already crossed the trust
/// boundary. Stricter than the design's "mtime"-only invalidation (it also
/// folds in path set + size). Cf. docs/plugins-design.md §14 #9.
public static func signature(directory: URL) throws -> String {
    let files = try regularFiles(in: directory)
    var parts: [String] = []
    parts.reserveCapacity(files.count)
    for file in files {
        let values = try file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        parts.append("\(file.rel)\u{0}\(mtime)\u{0}\(size)")
    }
    return parts.joined(separator: "\n")
}

/// Sorted regular files (hidden included) under `directory`, as (relative path,
/// url). Shared by `hash` and `signature` so both cover the exact same set.
private static func regularFiles(in directory: URL) throws -> [(rel: String, url: URL)] {
    let fm = FileManager.default
    let base = directory.standardizedFileURL
    guard
        let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
    else {
        throw PluginError.ioError("cannot enumerate \(base.path)")
    }
    var files: [(rel: String, url: URL)] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let absPath = url.standardizedFileURL.path
        let prefix = base.path + "/"
        guard absPath.hasPrefix(prefix) else {
            throw PluginError.ioError("path \(absPath) outside base \(base.path)")
        }
        let rel = String(absPath.dropFirst(prefix.count))
        files.append((rel: rel, url: url))
    }
    files.sort { $0.rel < $1.rel }
    return files
}
```

- [ ] **Step 4 — Ajouter le cache dans `PluginRegistry`**

Dans `PluginRegistry.swift`, après les propriétés stockées (~`private let fm`), ajouter :

```swift
/// Memoised content hash per plugin id, keyed on a cheap stat-only signature.
/// `view`/`enable` re-hash on every `list`/`info`; the cache returns the pinned
/// digest unchanged unless the tree's signature moved (#9). Actor-isolated, so
/// no locking. Invalidated on `remove`.
private struct CachedHash { let signature: String; let value: String }
private var hashCache: [String: CachedHash] = [:]

private func currentHash(id: String, directory: URL) throws -> String {
    let signature = try PluginHasher.signature(directory: directory)
    if let cached = hashCache[id], cached.signature == signature {
        return cached.value
    }
    let value = try PluginHasher.hash(directory: directory)
    hashCache[id] = CachedHash(signature: signature, value: value)
    return value
}
```

Dans `view(for:)`, remplacer :

```swift
let currentHash = try PluginHasher.hash(directory: directory(for: entry.id))
```

par :

```swift
let currentHash = try currentHash(id: entry.id, directory: directory(for: entry.id))
```

Dans `enable(id:)`, remplacer :

```swift
let currentHash = try PluginHasher.hash(directory: directory(for: id))
```

par :

```swift
let currentHash = try currentHash(id: id, directory: directory(for: id))
```

Dans `remove(id:)`, après le `do/catch` de `removeItem`, ajouter (invalidation) :

```swift
hashCache[id] = nil
```

- [ ] **Step 5 — Test de non-régression registry (cache correct sous tamper)**

Les tests existants `testListReportsNeedsReapprovalAfterTamper` et `testEnableThrowsOnHashMismatch` couvrent déjà l'invalidation correcte (le tamper change la taille → signature change → recompute → mismatch détecté). Aucun nouveau test requis ici ; vérifier qu'ils restent verts.

- [ ] **Step 6 — Build + tests**

Run: `swift build` puis `swift test --filter PluginHasherTests` puis `swift test --filter PluginRegistryTests`
Expected: PASS partout.

- [ ] **Step 7 — Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHasher.swift Sources/IrisKit/Plugins/PluginRegistry.swift Tests/IrisKitTests/Plugins/PluginHasherTests.swift
git commit -m "feat(plugins): cache de hash via signature stat-only (durcissement §14 #9)"
```

---

## Task 4 — #8 : refus des symlinks + caps taille/nombre

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginSourceValidator.swift`
- Modify: `Sources/IrisKit/Plugins/PluginManifest.swift` (enum `PluginError`)
- Modify: `Sources/IrisKit/IPC/JSONRPC.swift`, `Sources/IrisKit/IPC/AdminDispatcher.swift`
- Modify: `Sources/IrisKit/Plugins/PluginRegistry.swift` (`install` : appel du validator + `sourceLimits`)
- Test: `Tests/IrisKitTests/Plugins/PluginSourceValidatorTests.swift` (créer), `PluginRegistryTests.swift`

- [ ] **Step 1 — Ajouter le cas d'erreur + le code RPC + le mapping**

Dans `PluginManifest.swift`, enum `PluginError`, ajouter le cas après `case ioError(String)` :

```swift
case unsafeSource(String)
```

et dans `errorDescription` :

```swift
case .unsafeSource(let reason): return "Unsafe plugin source: \(reason)"
```

Dans `JSONRPC.swift`, après `pluginIOError` :

```swift
public static let pluginUnsafeSource = JSONRPCError(code: -32035, message: "unsafe plugin source")
```

Dans `AdminDispatcher.mapPluginError`, ajouter un case avant le `}` :

```swift
case .unsafeSource:
    return JSONRPCError(code: JSONRPCError.pluginUnsafeSource.code, message: error.localizedDescription)
```

- [ ] **Step 2 — Écrire les tests qui échouent**

Créer `Tests/IrisKitTests/Plugins/PluginSourceValidatorTests.swift` :

```swift
import XCTest

@testable import IrisKit

final class PluginSourceValidatorTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("srcval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAcceptsPlainTree() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try PluginSourceValidator.validate(directory: dir))
    }

    func testRejectsSymlink() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "real".write(to: dir.appendingPathComponent("real"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link"),
            withDestinationURL: dir.appendingPathComponent("real")
        )
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }

    func testRejectsTooManyFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 {
            try "x".write(to: dir.appendingPathComponent("f\(i)"), atomically: true, encoding: .utf8)
        }
        let limits = PluginSourceValidator.Limits(maxFileCount: 3, maxTotalBytes: 1_000_000)
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir, limits: limits)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }

    func testRejectsTooLarge() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "x", count: 2000).write(
            to: dir.appendingPathComponent("big"), atomically: true, encoding: .utf8)
        let limits = PluginSourceValidator.Limits(maxFileCount: 100, maxTotalBytes: 1000)
        XCTAssertThrowsError(try PluginSourceValidator.validate(directory: dir, limits: limits)) { error in
            guard case PluginError.unsafeSource = error else {
                return XCTFail("expected unsafeSource, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 3 — Lancer, vérifier l'échec**

Run: `swift test --filter PluginSourceValidatorTests`
Expected: FAIL — `PluginSourceValidator` n'existe pas.

- [ ] **Step 4 — Implémenter `PluginSourceValidator`**

Créer `Sources/IrisKit/Plugins/PluginSourceValidator.swift` :

```swift
import Foundation

/// Validates a client-supplied plugin source tree before it is copied into the
/// per-user plugins dir (design §14 #8). Two guarantees, both fail-closed:
///
/// 1. **No symbolic links.** `PluginHasher` only folds regular files into the
///    TOFU pin, so a symlink is unpinned — its target could change after install
///    without moving the hash, and an absolute link could point outside the
///    bundle. A legitimate plugin bundle needs no symlinks, so we refuse any.
/// 2. **Bounded size/count.** A verbatim copy of an arbitrary directory is a DoS
///    vector (disk fill, huge re-hash). Cap total bytes and file count.
///
/// Pure I/O over the source dir; no mutation.
public enum PluginSourceValidator {
    public struct Limits: Sendable {
        public let maxFileCount: Int
        public let maxTotalBytes: Int
        public init(maxFileCount: Int = 10_000, maxTotalBytes: Int = 100 * 1024 * 1024) {
            self.maxFileCount = maxFileCount
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public static func validate(directory: URL, limits: Limits = Limits()) throws {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory.standardizedFileURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else {
            throw PluginError.ioError("cannot enumerate source \(directory.path)")
        }
        var fileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw PluginError.unsafeSource("contains a symbolic link: \(url.lastPathComponent)")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            if fileCount > limits.maxFileCount {
                throw PluginError.unsafeSource("too many files (> \(limits.maxFileCount))")
            }
            totalBytes += values.fileSize ?? 0
            if totalBytes > limits.maxTotalBytes {
                throw PluginError.unsafeSource("source too large (> \(limits.maxTotalBytes) bytes)")
            }
        }
    }
}
```

- [ ] **Step 5 — Lancer, vérifier le passage**

Run: `swift test --filter PluginSourceValidatorTests`
Expected: PASS.

- [ ] **Step 6 — Brancher le validator dans `install` + rendre les limites injectables**

Dans `PluginRegistry.swift`, ajouter une propriété stockée + paramètre d'init :

```swift
private let sourceLimits: PluginSourceValidator.Limits
```

et dans `init` :

```swift
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
```

Dans `install(from:)`, juste après `try manifest.validate()` :

```swift
try PluginSourceValidator.validate(directory: sourceDir, limits: sourceLimits)
```

- [ ] **Step 7 — Test d'intégration registry : install refuse une source à symlink**

Dans `PluginRegistryTests.swift`, ajouter :

```swift
func testInstallRejectsSourceWithSymlink() async throws {
    let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
    let src = try writeSource(id: "sym.id")
    defer { try? FileManager.default.removeItem(at: src) }
    try FileManager.default.createSymbolicLink(
        at: src.appendingPathComponent("evil"),
        withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
    )
    await assertThrowsAsyncError(try await reg.install(from: src)) { error in
        guard case PluginError.unsafeSource = error else {
            return XCTFail("expected unsafeSource, got \(error)")
        }
    }
    // Nothing committed, nothing copied.
    let count = await store.plugins().count
    XCTAssertEqual(count, 0)
}
```

- [ ] **Step 8 — Build + tests**

Run: `swift build` puis `swift test --filter PluginSourceValidatorTests` puis `swift test --filter PluginRegistryTests`
Expected: PASS partout.

- [ ] **Step 9 — Commit**

```bash
git add Sources/IrisKit/Plugins/PluginSourceValidator.swift Sources/IrisKit/Plugins/PluginManifest.swift Sources/IrisKit/IPC/JSONRPC.swift Sources/IrisKit/IPC/AdminDispatcher.swift Sources/IrisKit/Plugins/PluginRegistry.swift Tests/IrisKitTests/Plugins/PluginSourceValidatorTests.swift Tests/IrisKitTests/Plugins/PluginRegistryTests.swift
git commit -m "feat(plugins): refuser symlinks + borner taille/nombre à l'install (durcissement §14 #8)"
```

---

## Task 5 — #6 : install transactionnel (staging → commit → rename)

**Files:**
- Modify: `Sources/IrisKit/Plugins/PluginRegistry.swift` (`install(from:)`)
- Test: `Tests/IrisKitTests/Plugins/PluginRegistryTests.swift`

- [ ] **Step 1 — Écrire le test qui échoue (ou verrouille l'invariant)**

Dans `PluginRegistryTests.swift`, ajouter un test de concurrence : deux `install` du même id en parallèle → un seul réussit, et le dossier du gagnant survit (le rollback du perdant ne l'efface pas).

```swift
func testConcurrentInstallSameIdLeavesWinnerDirectoryIntact() async throws {
    let reg = PluginRegistry(pluginsDirectory: root, configStore: store, logger: logger)
    let srcA = try writeSource(id: "race.id")
    let srcB = try writeSource(id: "race.id")
    defer { try? FileManager.default.removeItem(at: srcA); try? FileManager.default.removeItem(at: srcB) }

    async let a: Plugin? = try? await reg.install(from: srcA)
    async let b: Plugin? = try? await reg.install(from: srcB)
    let (ra, rb) = await (a, b)

    // Exactly one install succeeded.
    let successes = [ra, rb].compactMap { $0 }
    XCTAssertEqual(successes.count, 1)

    // The committed entry and its on-disk directory both exist and agree —
    // the loser's rollback must not have deleted the winner's committed dir.
    let entries = await store.plugins()
    XCTAssertEqual(entries.map(\.id), ["race.id"])
    let plugin = try await reg.info(id: "race.id")
    XCTAssertTrue(plugin.hashMatches)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("race.id").path))

    // No staging crumbs left behind.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix(".staging-") }
    XCTAssertEqual(leftovers, [])
}
```

- [ ] **Step 2 — Lancer, observer**

Run: `swift test --filter PluginRegistryTests/testConcurrentInstallSameIdLeavesWinnerDirectoryIntact`
Expected: peut être FLAKY/FAIL avec l'install actuel (copie-avant-commit + rollback `removeItem(dest)` du perdant peut effacer le dossier committé du gagnant, et/ou `info` voit un manifest manquant). Établit le besoin du staging.

- [ ] **Step 3 — Réécrire `install(from:)` en staging → commit → rename**

Remplacer le corps de `install(from:)` (de `let hash = ...` jusqu'au `return Plugin(...)`) par :

```swift
let hash = try PluginHasher.hash(directory: sourceDir)

// Stage the copy under a unique temp dir INSIDE the plugins dir (same volume →
// atomic rename later). The state is committed BEFORE the rename, so a rollback
// only ever deletes our own staging dir — never a directory another concurrent
// install of the same id already committed (#6).
try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
let staging = pluginsDirectory.appendingPathComponent(
    ".staging-\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
do {
    try fm.copyItem(at: sourceDir, to: staging)
} catch {
    try? fm.removeItem(at: staging)
    throw PluginError.ioError("stage plugin \(manifest.id): \(error)")
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
    try? fm.removeItem(at: staging)  // rollback touches only our staging dir
    throw error
}
guard let newEntry = entries.first(where: { $0.id == manifest.id }) else {
    try? fm.removeItem(at: staging)
    throw PluginError.ioError("install: entry missing after persist for \(manifest.id)")
}

// Move staging into place AFTER the commit. Only one install wins the atomic
// dup re-check above, so only one reaches here for a given id — no rename race.
let dest = try directory(for: manifest.id)
do {
    if fm.fileExists(atPath: dest.path) {
        logger.warning(
            "install: replacing pre-existing plugin directory with no state entry",
            metadata: ["id": "\(manifest.id)"]
        )
        try fm.removeItem(at: dest)
    }
    try fm.moveItem(at: staging, to: dest)
} catch {
    // State is committed but the directory isn't in place. Restore consistency:
    // best-effort roll the entry back and clean staging, then fail loud (§12).
    try? fm.removeItem(at: staging)
    _ = try? await configStore.updatePlugins { $0.filter { $0.id != manifest.id } }
    throw PluginError.ioError("place plugin \(manifest.id): \(error)")
}

// hashMatches is true by construction (we just hashed + pinned the same tree).
return Plugin(
    manifest: manifest,
    enabled: newEntry.enabled,
    order: newEntry.order,
    approvedCapabilities: newEntry.approvedCapabilities,
    pinnedHash: newEntry.pinnedHash,
    hashMatches: true
)
```

- [ ] **Step 4 — Lancer, vérifier le passage**

Run: `swift test --filter PluginRegistryTests`
Expected: PASS (tous, dont le test de concurrence et les anciens `testInstall*`).

- [ ] **Step 5 — Build + suite complète**

Run: `swift build` puis `swift test`
Expected: build OK ; suite verte (≥ 634 + nouveaux tests).

- [ ] **Step 6 — Lint CI exact**

Run: `swift-format lint --strict --recursive Sources Tests Package.swift IrisApp`
Expected: exit 0.

- [ ] **Step 7 — Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRegistry.swift Tests/IrisKitTests/Plugins/PluginRegistryTests.swift
git commit -m "feat(plugins): install transactionnel staging→commit→rename (durcissement §14 #6)"
```

---

## Finalisation

- [ ] **Mettre à jour le design** : dans `docs/plugins-design.md` §14, marquer #6-#10 comme ✅ implémentés (référencer cette PR), et retirer/ajuster la note "à durcir en P2".
- [ ] **Vérification finale** : `swift build` + `swift test` + lint strict tous verts (evidence avant claim, CLAUDE.md §12).
- [ ] **Revue** : requesting-code-review (subagent reviewer) avant d'ouvrir la PR.
- [ ] **PR** : `feat/plugins-hardening-6-10` → `main`, description avec checklist de smoke testing (CLAUDE.md §8). Smoke : install d'un plugin avec symlink refusé ; install normal OK ; `iris plugin list` rapide (cache) ; manifest avec `network: ["x"]` (sans port) refusé.

---

## Self-Review (effectué)

**Couverture spec (§14 #6-10) :**
- #6 staging+rename → Task 5 ✅
- #7 id centralisé → Task 2 ✅
- #8 symlinks+caps → Task 4 ✅
- #9 cache re-hash → Task 3 ✅
- #10 forme capabilities → Task 1 ✅

**Cohérence des types :** `PluginError.unsafeSource(String)` défini Task 4, mappé Task 4 (RPC -32035), utilisé par `PluginSourceValidator` Task 4. `directory(for:) throws` introduit Task 2, consommé inchangé par Tasks 3-5. `currentHash(id:directory:)` défini Task 3, signature stable. `PluginSourceValidator.Limits` défini Task 4, injecté via `PluginRegistry.init(sourceLimits:)` Task 4.

**Ordre :** #10 (isolé) → #7 (signature throwing) → #9 (cache, build sur directory throwing) → #8 (validator + error) → #6 (réécriture install, build sur tout). Pas de dépendance arrière.

**Points de vigilance d'exécution :**
- Task 2 Step 3 : `view(for:)` est retouché en Task 3 (cache). À l'issue de Task 2, `view` appelle `try PluginHasher.hash(directory: try directory(...))` — bien mettre les deux `try`.
- Task 3 : vérifier que `makeTree` n'existe pas déjà dans `PluginHasherTests.swift` avant de l'ajouter (sinon réutiliser).
- Task 5 : le test de concurrence s'appuie sur la réentrance de l'actor aux `await` ; il prouve l'invariant de rollback, pas un timing déterministe.
