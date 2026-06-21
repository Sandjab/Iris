# Plugins P2b — Lifecycle process chaud + IPC NDJSON — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faire tourner les plugins IRIS comme des sous-process **chauds** sandboxés : le daemon les lance, exécute un handshake `initialize` en NDJSON, les maintient vivants entre les requêtes, les arrête proprement, les redémarre avec backoff sur crash, et les auto-désactive (avec `SystemAlert`) après des crashes répétés.

**Architecture :** Trois acteurs/types dans `Sources/IrisKit/Plugins/`. `PluginRPC` porte les types fil (envelope JSON-RPC 2.0 réutilisée, framing NDJSON compact + `\n`). `PluginHost` (acteur) possède **un** process : spawn via `PluginSandbox` (Foundation.Process + shim Seatbelt P2a), lecteur NDJSON `DispatchSource` → `AsyncStream`, handshake `initialize`, `shutdown` gracieux → SIGTERM → SIGKILL. `PluginHostManager` (acteur) possède **tous** les hosts : lancement au boot, `reconcile()` après mutation (diff de l'ensemble activé), restart/backoff exponentiel, auto-désactivation au seuil. Câblage dans `Daemon.swift` + nouveau callback `onPluginsChanged` sur `AdminDispatcher`. **Invariant §3 intact** : `initialize` ne porte que des `config_values` non-secrets + les capabilities accordées — aucune donnée de requête (`onRequest` = P3).

**Tech Stack :** Swift 5.9 / SwiftPM, `-strict-concurrency=complete`, `Foundation.Process`/`Pipe`/`FileHandle`, `DispatchSource` (lecteur de pipe), Swift Concurrency (acteurs, `CheckedContinuation`, `Task.sleep`), Seatbelt via `PluginSandbox` (P2a), réutilisation `JSONRPCRequest/Response/JSONValue/JSONRPCCoder` (`Sources/IrisKit/IPC/JSONRPC.swift`), XCTest.

**Conventions repo (rappel) :**
- Tous les commits : préfixe conventional + trailer `Claude-Session:` (CLAUDE.md §8). Les exemples omettent le trailer pour la lisibilité — l'ajouter à chaque commit.
- `swift-format` : 120 col, 4 espaces, **1 argument par ligne** sur les appels multi-args. CI lint = `swift format lint --strict --recursive Sources Tests Package.swift IrisApp` (`--strict` transforme camelCase warnings en erreurs).
- Tests : **XCTest uniquement**. Unitaires purs → `Tests/IrisKitTests/` ; tests spawnant des process → `Tests/IntegrationTests/`.
- `Thread.sleep` interdit dans le daemon (CLAUDE.md §10) → `Task.sleep` partout. Les helpers de polling **de test** peuvent attendre (borné), comme en P2a.

**Portée P2b (ce qui N'est PAS fait ici, → P3) :** dispatch `onRequest`, insertion `MITMHandler.processRequest`, events plugin par-requête, syntaxe SBPL réseau-allow (reste `PROVISIONAL`, aucun plugin réseau exercé), UI Plugins. Le `.pkg` devra embarquer + signer `iris-sandbox-exec` à côté d'`irisd` (territoire Phase 9) — **suivi hors-P2b** ; en dev `swift build` place les deux dans `.build/debug/`, donc P2b reste démontrable.

---

## File Structure

| Fichier | Création/Modif | Responsabilité |
|---|---|---|
| `Sources/IrisKit/Plugins/PluginRPC.swift` | Create | Types fil : `InitializeParams`/`InitializeResult`, encode compact + `\n`, décode ligne→`JSONRPCResponse`. |
| `Sources/IrisKit/Plugins/PluginBackoffPolicy.swift` | Create | Pure : délai de restart exponentiel plafonné + `shouldDisable`. |
| `Sources/IrisKit/Plugins/PluginLineReader.swift` | Create | Lecteur NDJSON non-bloquant (`DispatchSource`) d'un fd → lignes + EOF. |
| `Sources/IrisKit/Plugins/PluginHost.swift` | Create | Acteur : lifecycle d'**un** process + transport IPC. |
| `Sources/IrisKit/Plugins/PluginHostManager.swift` | Create | Acteur : orchestration de tous les hosts, reconcile, backoff, auto-disable. |
| `Sources/IrisKit/Plugins/PluginSandbox.swift` | Modify | + params `standardInput:` et `currentDirectory:` à `launch`. |
| `Sources/iris-test-plugin/main.swift` | Create | Fixture de test : mini-serveur NDJSON (modes `ok`/`crash`/`ignore-shutdown`). |
| `Package.swift` | Modify | + cible `iris-test-plugin` (non-product) ; + dépendance d'`IntegrationTests`. |
| `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift` | Modify | + `testPlugin`. |
| `Sources/IrisKit/IPC/AdminDispatcher.swift` | Modify | + `onPluginsChanged` (callback) appelé par enable/disable/remove/reorder. |
| `Sources/irisd/Daemon.swift` | Modify | + params `sandboxExecPath`/`scratchRoot`, construire `PluginHostManager`, `startEnabled()` au run, `shutdownAll()` au stop, câbler `onPluginsChanged`. |
| `Sources/irisd/App.swift` | Modify | Résoudre `sandboxExecPath` à côté de l'exécutable + passer à `Daemon`. |
| `Tests/IrisKitTests/PluginRPCTests.swift` | Create | Unitaires `PluginRPC`. |
| `Tests/IrisKitTests/PluginBackoffPolicyTests.swift` | Create | Unitaires backoff. |
| `Tests/IrisKitTests/PluginLineReaderTests.swift` | Create | Unitaires lecteur (réassemblage de lignes partielles, EOF). |
| `Tests/IntegrationTests/PluginHostTests.swift` | Create | Handshake `initialize` réel sous sandbox + `shutdown`/SIGKILL. |
| `Tests/IntegrationTests/PluginHostManagerTests.swift` | Create | reconcile (start/stop), crash-loop → auto-disable + `SystemAlert`. |
| `Tests/IntegrationTests/PluginDaemonWiringTests.swift` | Create | Boot daemon avec plugin activé → handshake bout-en-bout (marqueur scratch). |

---

## Task 1 : Types fil `PluginRPC` (NDJSON + JSON-RPC 2.0)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginRPC.swift`
- Test: `Tests/IrisKitTests/PluginRPCTests.swift`

- [ ] **Step 1 : Écrire les tests d'abord**

Create `Tests/IrisKitTests/PluginRPCTests.swift` :

```swift
import XCTest

@testable import IrisKit

final class PluginRPCTests: XCTestCase {
    func testEncodeRequestIsSingleCompactLineTerminatedByNewline() throws {
        let params = PluginRPC.InitializeParams(
            apiVersion: 1,
            configValues: ["k": "v"],
            capabilities: PluginCapabilities(network: [], filesystem: []),
            scratchDir: "/tmp/scratch"
        )
        let line = try PluginRPC.encodeRequest(
            method: "initialize",
            params: params,
            id: 7
        )
        // Exactly one trailing newline, no embedded newlines.
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains("\"method\":\"initialize\""))
        XCTAssertTrue(line.contains("\"api_version\":1"))
        XCTAssertTrue(line.contains("\"scratch_dir\":\"/tmp/scratch\""))
        XCTAssertTrue(line.contains("\"id\":7"))
    }

    func testEncodeNotificationHasNoId() throws {
        let line = try PluginRPC.encodeNotification(method: "shutdown")
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertFalse(line.contains("\"id\""))
        XCTAssertTrue(line.contains("\"method\":\"shutdown\""))
    }

    func testDecodeResponseParsesResultAndId() throws {
        let response = try PluginRPC.decodeResponse(
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ready\":true}}"
        )
        XCTAssertEqual(response.id, .integer(7))
        let result = try XCTUnwrap(response.result).decode(as: PluginRPC.InitializeResult.self)
        XCTAssertTrue(result.ready)
    }

    func testDecodeResponseRejectsGarbage() {
        XCTAssertThrowsError(try PluginRPC.decodeResponse("not json"))
    }
}
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter PluginRPCTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'PluginRPC' in scope`.

- [ ] **Step 3 : Implémenter `PluginRPC`**

Create `Sources/IrisKit/Plugins/PluginRPC.swift` :

```swift
import Foundation

/// Wire types and (de)serialization for the plugin IPC channel.
///
/// Transport is NDJSON: one **compact** JSON object per line, UTF-8, terminated
/// by `\n` (cf. docs/plugins-design.md §8). The envelope reuses the admin
/// JSON-RPC 2.0 types (`JSONRPCRequest`/`JSONRPCResponse`) and the shared
/// `JSONRPCCoder` (ISO-8601 dates, explicit snake_case `CodingKeys`). The
/// daemon is the client; the plugin is the server.
public enum PluginRPC {
    /// `initialize` params (daemon → plugin) at startup. Carries only non-secret
    /// config and the granted sandbox capabilities — never request data.
    public struct InitializeParams: Codable, Sendable, Equatable {
        public let apiVersion: Int
        public let configValues: [String: String]
        public let capabilities: PluginCapabilities
        /// Canonical (realpath-resolved) private scratch directory the plugin may
        /// write to. The sandbox allows writes only here (cf. PluginSandboxProfile).
        public let scratchDir: String

        enum CodingKeys: String, CodingKey {
            case apiVersion = "api_version"
            case configValues = "config_values"
            case capabilities
            case scratchDir = "scratch_dir"
        }

        public init(
            apiVersion: Int,
            configValues: [String: String],
            capabilities: PluginCapabilities,
            scratchDir: String
        ) {
            self.apiVersion = apiVersion
            self.configValues = configValues
            self.capabilities = capabilities
            self.scratchDir = scratchDir
        }
    }

    /// `initialize` result (plugin → daemon): the plugin confirms it is ready.
    public struct InitializeResult: Codable, Sendable, Equatable {
        public let ready: Bool

        public init(ready: Bool) {
            self.ready = ready
        }
    }

    /// Methods spoken on the channel. P2b uses `initialize` (request) and
    /// `shutdown` (notification); `onRequest` lands in P3.
    public enum Method {
        public static let initialize = "initialize"
        public static let shutdown = "shutdown"
    }

    /// Encodes a request as a single compact NDJSON line (trailing `\n`).
    public static func encodeRequest<P: Encodable>(
        method: String,
        params: P,
        id: Int64
    ) throws -> String {
        let request = JSONRPCRequest(
            method: method,
            params: try JSONValue.encoding(params),
            id: .integer(id)
        )
        return try line(from: request)
    }

    /// Encodes a notification (no `id`, no response expected) as one NDJSON line.
    public static func encodeNotification(method: String) throws -> String {
        // A notification omits `id` entirely; build the object directly so no
        // `id` key is emitted (JSONRPCRequest always carries one).
        let object = JSONValue.object([
            "jsonrpc": .string(JSONRPCRequest.version),
            "method": .string(method),
        ])
        return try line(from: object)
    }

    /// Parses one NDJSON line into a `JSONRPCResponse`.
    public static func decodeResponse(_ line: String) throws -> JSONRPCResponse {
        let data = Data(line.utf8)
        return try JSONRPCCoder.makeDecoder().decode(JSONRPCResponse.self, from: data)
    }

    /// Compact single-line encoding + `\n`. `JSONEncoder` never emits newlines
    /// unless `.prettyPrinted`, so the output is guaranteed single-line.
    private static func line<T: Encodable>(from value: T) throws -> String {
        let data = try JSONRPCCoder.makeEncoder().encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
```

> Note : `JSONRPCCoder.makeEncoder()` active `.sortedKeys`, donc les assertions de sous-chaîne du test ci-dessus reposent sur l'ordre alphabétique des clés au sein de chaque objet (`api_version` avant `capabilities` avant `config_values` avant `scratch_dir` ; `id` avant `method` avant `result`). Les assertions ne testent que des paires clé:valeur isolées, robustes à l'ordre global.

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter PluginRPCTests 2>&1 | tail -10`
Expected: PASS (4 tests). **Si une assertion de sous-chaîne échoue** : vérifier l'ordre des clés produit par `.sortedKeys` et ajuster la sous-chaîne (ne pas désactiver `.sortedKeys` — c'est la convention du coder partagé).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginRPC.swift Tests/IrisKitTests/PluginRPCTests.swift
git commit -m "feat(plugins): types fil PluginRPC (NDJSON + JSON-RPC 2.0)"
```

---

## Task 2 : Politique de backoff (`PluginBackoffPolicy`)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginBackoffPolicy.swift`
- Test: `Tests/IrisKitTests/PluginBackoffPolicyTests.swift`

- [ ] **Step 1 : Écrire les tests d'abord**

Create `Tests/IrisKitTests/PluginBackoffPolicyTests.swift` :

```swift
import XCTest

@testable import IrisKit

final class PluginBackoffPolicyTests: XCTestCase {
    private let policy = PluginBackoffPolicy(
        initialBackoff: 0.25,
        maxBackoff: 30,
        crashThreshold: 5
    )

    func testDelayIsExponentialFromTheInitialValue() {
        XCTAssertEqual(policy.delay(forCrashCount: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forCrashCount: 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forCrashCount: 3), 1.0, accuracy: 1e-9)
    }

    func testDelayIsCappedAtMaxBackoff() {
        XCTAssertEqual(policy.delay(forCrashCount: 20), 30, accuracy: 1e-9)
    }

    func testDelayForZeroOrNegativeIsTheInitialValue() {
        XCTAssertEqual(policy.delay(forCrashCount: 0), 0.25, accuracy: 1e-9)
    }

    func testShouldDisableAtThreshold() {
        XCTAssertFalse(policy.shouldDisable(recentCrashCount: 4))
        XCTAssertTrue(policy.shouldDisable(recentCrashCount: 5))
        XCTAssertTrue(policy.shouldDisable(recentCrashCount: 6))
    }
}
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter PluginBackoffPolicyTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'PluginBackoffPolicy' in scope`.

- [ ] **Step 3 : Implémenter la politique**

Create `Sources/IrisKit/Plugins/PluginBackoffPolicy.swift` :

```swift
import Foundation

/// Pure restart/backoff policy for a crashing plugin process (cf.
/// docs/plugins-design.md §14 #5). Exponential backoff capped at `maxBackoff`;
/// a plugin that crashes `crashThreshold` times within the manager's sliding
/// window is auto-disabled. All values are injectable so tests can shrink them.
public struct PluginBackoffPolicy: Sendable, Equatable {
    public let initialBackoff: TimeInterval
    public let maxBackoff: TimeInterval
    public let crashThreshold: Int

    public init(
        initialBackoff: TimeInterval = 0.25,
        maxBackoff: TimeInterval = 30,
        crashThreshold: Int = 5
    ) {
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.crashThreshold = crashThreshold
    }

    /// Delay before the `crashCount`-th restart: `initial * 2^(crashCount-1)`,
    /// capped at `maxBackoff`. `crashCount <= 1` returns `initialBackoff`.
    public func delay(forCrashCount crashCount: Int) -> TimeInterval {
        let exponent = max(0, crashCount - 1)
        let scaled = initialBackoff * pow(2, Double(exponent))
        return min(scaled, maxBackoff)
    }

    /// Whether a plugin with `recentCrashCount` crashes inside the sliding
    /// window should be auto-disabled.
    public func shouldDisable(recentCrashCount: Int) -> Bool {
        recentCrashCount >= crashThreshold
    }
}
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter PluginBackoffPolicyTests 2>&1 | tail -10`
Expected: PASS (4 tests).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginBackoffPolicy.swift \
        Tests/IrisKitTests/PluginBackoffPolicyTests.swift
git commit -m "feat(plugins): politique de backoff exponentiel + seuil d'auto-disable"
```

---

## Task 3 : Fixture de test `iris-test-plugin` + entrées/sorties sandbox

**Files:**
- Create: `Sources/iris-test-plugin/main.swift`
- Modify: `Package.swift`
- Modify: `Sources/IrisKit/Plugins/PluginSandbox.swift`
- Modify: `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift`

- [ ] **Step 1 : Écrire la fixture NDJSON**

Create `Sources/iris-test-plugin/main.swift` :

```swift
import Foundation

// iris-test-plugin — minimal NDJSON plugin server used ONLY by IRIS P2b
// integration tests. Not shipped (no product entry in Package.swift).
//
// Reads one JSON object per line from stdin, replies on stdout. Mode comes from
// argv[1] (default "ok"):
//   ok               normal: replies ready to initialize, writes an
//                    "initialized" marker into scratch_dir, exits on shutdown.
//   crash            exits non-zero immediately (drives crash-loop tests).
//   ignore-shutdown  replies ready but never exits on shutdown (drives the
//                    SIGTERM/SIGKILL path).

let mode = CommandLine.arguments.dropFirst().first ?? "ok"

if mode == "crash" {
    exit(3)
}

func emitLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    let method = object["method"] as? String
    let id = object["id"] ?? NSNull()

    switch method {
    case "initialize":
        if let params = object["params"] as? [String: Any],
            let scratch = params["scratch_dir"] as? String
        {
            let marker = (scratch as NSString).appendingPathComponent("initialized")
            try? Data("ok".utf8).write(to: URL(fileURLWithPath: marker))
        }
        emitLine(["jsonrpc": "2.0", "id": id, "result": ["ready": true]])
    case "shutdown":
        if mode == "ignore-shutdown" { continue }
        exit(0)
    default:
        break
    }
}
exit(0)
```

- [ ] **Step 2 : Déclarer la cible dans `Package.swift`**

Dans le tableau `targets`, ajouter après la cible `iris-sandbox-exec` (la fixture n'est **pas** un product — non shipée) :

```swift
        .executableTarget(
            name: "iris-test-plugin",
            swiftSettings: strictConcurrency
        ),
```

Dans la cible `IntegrationTests`, ajouter `"iris-test-plugin"` à la liste `dependencies` (après `"iris-sandbox-exec",`) pour que SwiftPM la compile avant les tests.

- [ ] **Step 3 : Localisateur de la fixture**

Dans `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift`, ajouter après la ligne `static var sandboxExec: URL { url(forProduct: "iris-sandbox-exec") }` :

```swift
    static var testPlugin: URL { url(forProduct: "iris-test-plugin") }
```

- [ ] **Step 4 : Ajouter `standardInput`/`currentDirectory` à `PluginSandbox.launch`**

Dans `Sources/IrisKit/Plugins/PluginSandbox.swift`, modifier la signature et le corps de `launch` pour ajouter les deux paramètres (le plugin doit recevoir son stdin, et son cwd = scratch facilite l'écriture confinée). Remplacer la déclaration de `launch(...)` actuelle par :

```swift
    public func launch(
        executable: String,
        arguments: [String] = [],
        profile: String,
        currentDirectory: URL? = nil,
        standardInput: Pipe? = nil,
        standardOutput: Pipe? = nil,
        standardError: Pipe? = nil
    ) throws -> Process {
        let profileURL =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugin-\(UUID().uuidString).sb")
        try profile.write(to: profileURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = shimPath
        process.arguments = [profileURL.path, executable] + arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let standardInput {
            process.standardInput = standardInput
        }
        if let standardOutput {
            process.standardOutput = standardOutput
        }
        if let standardError {
            process.standardError = standardError
        }
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: profileURL)
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: profileURL)
            throw error
        }
        return process
    }
```

- [ ] **Step 5 : Build — la fixture et le shim compilent**

Run: `swift build --product iris 2>&1 | tail -5 && swift build 2>&1 | tail -5`
Expected: `Build complete!`. La cible `iris-test-plugin` est bâtie (dépendance d'`IntegrationTests`). **Si erreur de compile sur la fixture** : corriger avant de continuer.

- [ ] **Step 6 : Smoke manuel de la fixture (hors sandbox, sanity)**

Run: `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"scratch_dir":"/tmp"}}\n{"jsonrpc":"2.0","method":"shutdown"}\n' | .build/debug/iris-test-plugin ok`
Expected: une ligne `{"...":...,"result":{"ready":true},...}` sur stdout puis sortie 0. **Si rien ne sort** : vérifier que `readLine` boucle bien et que `emitLine` écrit sur stdout.

- [ ] **Step 7 : Commit**

```bash
git add Sources/iris-test-plugin/main.swift Package.swift \
        Sources/IrisKit/Plugins/PluginSandbox.swift \
        Tests/IntegrationTests/CLISupport/ExecutableLocator.swift
git commit -m "test(plugins): fixture NDJSON iris-test-plugin + stdin/cwd sur PluginSandbox"
```

---

## Task 4 : Lecteur NDJSON non-bloquant (`PluginLineReader`)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginLineReader.swift`
- Test: `Tests/IrisKitTests/PluginLineReaderTests.swift`

- [ ] **Step 1 : Écrire les tests d'abord**

Create `Tests/IrisKitTests/PluginLineReaderTests.swift` :

```swift
import XCTest

@testable import IrisKit

final class PluginLineReaderTests: XCTestCase {
    func testReassemblesLinesAcrossWritesAndSignalsEOF() throws {
        let pipe = Pipe()
        let linesBox = LockedBox<[String]>([])
        let eof = expectation(description: "eof")

        let reader = PluginLineReader(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            onLine: { line in linesBox.mutate { $0.append(line) } },
            onEOF: { eof.fulfill() }
        )
        reader.start()

        let write = pipe.fileHandleForWriting
        // A line split across two writes, then two lines in one write.
        write.write(Data("hel".utf8))
        write.write(Data("lo\nwor".utf8))
        write.write(Data("ld\nthird\n".utf8))
        try write.close()

        wait(for: [eof], timeout: 5)
        reader.stop()
        XCTAssertEqual(linesBox.value, ["hello", "world", "third"])
    }

    /// Minimal thread-safe box for collecting reader callbacks off the test thread.
    final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ value: T) { storage = value }
        var value: T { lock.lock(); defer { lock.unlock() }; return storage }
        func mutate(_ body: (inout T) -> Void) {
            lock.lock(); defer { lock.unlock() }; body(&storage)
        }
    }
}
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter PluginLineReaderTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'PluginLineReader' in scope`.

- [ ] **Step 3 : Implémenter le lecteur**

Create `Sources/IrisKit/Plugins/PluginLineReader.swift` :

```swift
import Foundation

/// Reads NDJSON from a file descriptor (a plugin's stdout pipe) without blocking
/// a Swift Concurrency thread: a `DispatchSource` read source fires on its own
/// queue, drains the fd non-blockingly, and splits on `\n`. Each complete line
/// is delivered via `onLine`; end-of-stream via `onEOF`.
///
/// The buffer is confined to `queue` (the source serializes its handler), so the
/// `@unchecked Sendable` conformance is sound: no field is touched concurrently.
final class PluginLineReader: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let onLine: @Sendable (String) -> Void
    private let onEOF: @Sendable () -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var finished = false

    init(
        fileDescriptor: Int32,
        onLine: @escaping @Sendable (String) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.onLine = onLine
        self.onEOF = onEOF
        self.queue = DispatchQueue(label: "io.iris.plugin.reader")
    }

    func start() {
        // Non-blocking so reads inside the handler never stall the queue.
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source
        source.resume()
    }

    func stop() {
        queue.sync {
            guard !finished else { return }
            finished = true
            source?.cancel()
            source = nil
        }
    }

    private func drain() {
        guard !finished else { return }
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = scratch.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: scratch[0..<n])
                emitCompleteLines()
            } else if n == 0 {
                // EOF.
                finished = true
                source?.cancel()
                source = nil
                onEOF()
                return
            } else {
                // n < 0: EAGAIN/EWOULDBLOCK means "drained for now"; anything else
                // ends the stream.
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finished = true
                source?.cancel()
                source = nil
                onEOF()
                return
            }
        }
    }

    private func emitCompleteLines() {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            let line = String(decoding: lineData, as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...index)
            onLine(line)
        }
    }
}
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter PluginLineReaderTests 2>&1 | tail -15`
Expected: PASS. **Si le test hang (timeout sur `eof`)** : la fd n'a pas reçu EOF — vérifier que le test appelle bien `write.close()` ; **si `linesBox` contient des lignes mal découpées** : vérifier `emitCompleteLines` (offsets de `Data` non basés sur 0).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginLineReader.swift \
        Tests/IrisKitTests/PluginLineReaderTests.swift
git commit -m "feat(plugins): lecteur NDJSON non-bloquant PluginLineReader (DispatchSource)"
```

---

## Task 5 : Acteur `PluginHost` (un process chaud + IPC)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginHost.swift`
- Test: `Tests/IntegrationTests/PluginHostTests.swift`

- [ ] **Step 1 : Implémenter `PluginHost`**

Create `Sources/IrisKit/Plugins/PluginHost.swift` :

```swift
import Foundation
import Logging

/// Everything `PluginHost` needs to launch one plugin process. Built by the
/// manager from a `Plugin` view (manifest + approved state).
public struct PluginLaunchSpec: Sendable {
    public let id: String
    public let executablePath: String
    public let capabilities: PluginCapabilities
    public let configValues: [String: String]
    /// Canonical (realpath-resolved) private scratch dir; created by the manager.
    public let scratchDir: URL

    public init(
        id: String,
        executablePath: String,
        capabilities: PluginCapabilities,
        configValues: [String: String],
        scratchDir: URL
    ) {
        self.id = id
        self.executablePath = executablePath
        self.capabilities = capabilities
        self.configValues = configValues
        self.scratchDir = scratchDir
    }
}

public enum PluginHostError: Error, Equatable {
    case notRunning
    case timeout(String)
    case initializeRejected
}

/// Owns a single warm plugin process and its NDJSON IPC channel. Spawns via
/// `PluginSandbox` (Seatbelt shim), runs the `initialize` handshake, keeps the
/// process warm, and shuts it down gracefully (shutdown notification → SIGTERM →
/// SIGKILL). Unexpected exits are reported to the manager via `onUnexpectedExit`.
public actor PluginHost {
    public struct Timeouts: Sendable {
        public let initialize: TimeInterval
        public let shutdown: TimeInterval
        public init(initialize: TimeInterval = 5, shutdown: TimeInterval = 2) {
            self.initialize = initialize
            self.shutdown = shutdown
        }
    }

    private let spec: PluginLaunchSpec
    private let sandbox: PluginSandbox
    private let timeouts: Timeouts
    private let logger: Logger
    private let onUnexpectedExit: @Sendable (String) async -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader: PluginLineReader?
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var stopping = false

    public init(
        spec: PluginLaunchSpec,
        sandbox: PluginSandbox,
        timeouts: Timeouts = Timeouts(),
        logger: Logger,
        onUnexpectedExit: @escaping @Sendable (String) async -> Void
    ) {
        self.spec = spec
        self.sandbox = sandbox
        self.timeouts = timeouts
        self.logger = logger
        self.onUnexpectedExit = onUnexpectedExit
    }

    public var id: String { spec.id }

    /// Spawns the sandboxed process and performs the `initialize` handshake.
    /// Throws (and tears down) if the process fails to start or does not confirm
    /// `ready` within the initialize timeout.
    public func start() async throws {
        let profile = PluginSandboxProfile.generate(
            capabilities: spec.capabilities,
            scratchDir: spec.scratchDir.path
        )
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let process = try sandbox.launch(
            executable: spec.executablePath,
            arguments: [],
            profile: profile,
            currentDirectory: spec.scratchDir,
            standardInput: stdin,
            standardOutput: stdout,
            standardError: stderr
        )
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        let reader = PluginLineReader(
            fileDescriptor: stdout.fileHandleForReading.fileDescriptor,
            onLine: { [weak self] line in Task { await self?.handleLine(line) } },
            onEOF: { [weak self] in Task { await self?.handleEOF() } }
        )
        reader.start()
        self.reader = reader

        // Drain stderr at debug; plugin stderr is opaque (the plugin never sees
        // secrets) but we never parse it as protocol data.
        let id = spec.id
        let logger = self.logger
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            logger.debug(
                "plugin stderr",
                metadata: ["id": "\(id)", "bytes": "\(data.count)"]
            )
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        // Any post-spawn failure (timeout, error response, bad/false result)
        // must tear the process down — otherwise a half-initialised plugin leaks.
        do {
            let response = try await send(
                method: PluginRPC.Method.initialize,
                params: PluginRPC.InitializeParams(
                    apiVersion: PluginManifest.supportedApiVersion,
                    configValues: spec.configValues,
                    capabilities: spec.capabilities,
                    scratchDir: spec.scratchDir.path
                )
            )
            guard let result = response.result else {
                throw PluginHostError.initializeRejected
            }
            let initialized = try result.decode(as: PluginRPC.InitializeResult.self)
            guard initialized.ready else {
                throw PluginHostError.initializeRejected
            }
            logger.info("plugin initialized", metadata: ["id": "\(spec.id)"])
        } catch {
            await teardown()
            throw error
        }
    }

    /// Graceful stop: send `shutdown`, wait, escalate to SIGTERM then SIGKILL.
    /// Idempotent; sets `stopping` so the termination handler does not report an
    /// unexpected exit.
    public func shutdown() async {
        guard let process, process.isRunning else {
            await teardown()
            return
        }
        stopping = true
        if let line = try? PluginRPC.encodeNotification(method: PluginRPC.Method.shutdown) {
            try? stdinHandle?.write(contentsOf: Data(line.utf8))
        }
        if await waitForExit(within: timeouts.shutdown) {
            await teardown()
            return
        }
        process.terminate()  // SIGTERM
        if await waitForExit(within: 1) {
            await teardown()
            return
        }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(within: 1)
        await teardown()
    }

    // MARK: - IPC

    private func send<P: Encodable>(method: String, params: P) async throws -> JSONRPCResponse {
        let id = nextID
        nextID += 1
        let line = try PluginRPC.encodeRequest(method: method, params: params, id: id)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.initialize * 1_000_000_000))
            await self?.failPending(id: id, error: PluginHostError.timeout(method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // Registration happens-before any handleLine (both run on this actor),
            // so a fast reply cannot be missed.
            pending[id] = continuation
            do {
                guard let stdinHandle else { throw PluginHostError.notRunning }
                try stdinHandle.write(contentsOf: Data(line.utf8))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let response = try? PluginRPC.decodeResponse(line) else {
            logger.debug("plugin sent unparseable line", metadata: ["id": "\(spec.id)"])
            return
        }
        guard case .integer(let id) = response.id,
            let continuation = pending.removeValue(forKey: id)
        else {
            return  // unsolicited / unknown id
        }
        continuation.resume(returning: response)
    }

    private func failPending(id: Int64, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func handleEOF() {
        // stdout closed; the process is exiting. terminationHandler does the
        // restart bookkeeping — here we just fail any in-flight requests.
        failAllPending(error: PluginHostError.notRunning)
    }

    private func failAllPending(error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    private func handleTermination() async {
        failAllPending(error: PluginHostError.notRunning)
        guard !stopping else { return }
        await onUnexpectedExit(spec.id)
    }

    // MARK: - Helpers

    /// Polls the process up to `seconds` for exit. Uses `Task.sleep` (no
    /// `Thread.sleep`); messages/exits are quick so a 20ms poll is fine.
    private func waitForExit(within seconds: TimeInterval) async -> Bool {
        let deadlineSteps = max(1, Int(seconds / 0.02))
        for _ in 0..<deadlineSteps {
            if process?.isRunning != true { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return process?.isRunning != true
    }

    private func teardown() async {
        reader?.stop()
        reader = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        // Best-effort scratch cleanup (the temp profile is removed by the
        // sandbox termination handler).
        try? FileManager.default.removeItem(at: spec.scratchDir)
    }
}
```

> Note concurrence : `Process`/`FileHandle` ne sont pas `Sendable` mais sont **confinés à l'acteur** (jamais passés à travers une frontière d'isolation). Les closures `terminationHandler`/`readabilityHandler`/reader sont `@Sendable` et ne capturent que `self` (réf d'acteur, Sendable) via `[weak self]` + `Task`. C'est le même schéma que `CATrustStore`/`UpstreamClient`.

- [ ] **Step 2 : Écrire le test d'intégration du handshake**

Create `Tests/IntegrationTests/PluginHostTests.swift` :

```swift
import IrisKit
import Logging
import XCTest

/// Drives a real PluginHost against the iris-test-plugin fixture, through the
/// real PluginSandbox + iris-sandbox-exec shim. Proves the initialize handshake
/// and the graceful/forced shutdown paths end-to-end under the sandbox.
final class PluginHostTests: XCTestCase {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seatbelt canonicalises write paths via realpath; the profile must carry
        // the canonical path or scratch writes fail closed (handoff #3).
        return URL(fileURLWithPath: dir.resolvingSymlinksInPath().realpath())
    }

    private func makeHost(scratch: URL) -> PluginHost {
        // Point straight at the fixture binary, which defaults to mode "ok"
        // (replies ready + writes the scratch marker). PluginSandbox passes no
        // argv to the plugin, matching production. Alternate fixture modes
        // (crash / ignore-shutdown) are exercised at the manager level (Task 6)
        // via an installed `run.sh` launcher that bakes the mode in.
        let spec = PluginLaunchSpec(
            id: "test.host",
            executablePath: ExecutableLocator.testPlugin.path,
            capabilities: PluginCapabilities(),
            configValues: [:],
            scratchDir: scratch
        )
        return PluginHost(
            spec: spec,
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1),
            logger: Logger(label: "test"),
            onUnexpectedExit: { _ in }
        )
    }

    func testInitializeHandshakeAndScratchMarker() async throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = makeHost(scratch: scratch)
        try await host.start()
        // The fixture writes an "initialized" marker into scratch_dir on initialize.
        let marker = scratch.appendingPathComponent("initialized")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "plugin should have written its scratch marker during initialize"
        )
        await host.shutdown()
    }
}

extension URL {
    /// Canonical filesystem path via realpath(3). `resolvingSymlinksInPath()` does
    /// not resolve the APFS `/var` firmlink, which Seatbelt requires (handoff #3).
    func realpath() -> String {
        path.withCString { cString in
            guard let resolved = Darwin.realpath(cString, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
```

- [ ] **Step 3 : Lancer le test du host**

Run: `swift test --filter PluginHostTests 2>&1 | tail -25`
Expected: PASS. **Si timeout sur `initialize`** : le handshake n'a pas abouti — vérifier (a) que la fixture écrit bien sur stdout (Task 3 Step 6), (b) que le lecteur reçoit les lignes, (c) que le scratch passé est `realpath`-résolu (sinon le marqueur n'est pas écrit, mais le handshake aboutit quand même — le marqueur est une assertion séparée). **Si le marqueur manque mais que le handshake passe** : le scratch n'était pas canonique → `(allow file-write* (subpath ...))` ne matche pas (handoff #3).

- [ ] **Step 4 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHost.swift \
        Tests/IntegrationTests/PluginHostTests.swift
git commit -m "feat(plugins): acteur PluginHost (process chaud + handshake NDJSON)"
```

---

## Task 6 : Acteur `PluginHostManager` (orchestration + backoff + auto-disable)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginHostManager.swift`
- Test: `Tests/IntegrationTests/PluginHostManagerTests.swift`

- [ ] **Step 1 : Implémenter le manager**

Create `Sources/IrisKit/Plugins/PluginHostManager.swift` :

```swift
import Foundation
import Logging

/// Owns every running plugin host. Reconciles the running set against the
/// registry's enabled set, restarts crashed plugins with exponential backoff,
/// and auto-disables a plugin that crashes past the policy threshold (emitting a
/// high-severity SystemAlert through the injected sink). Cf. docs/plugins-design.md
/// §8/§14 #5.
public actor PluginHostManager {
    public struct Configuration: Sendable {
        public let backoff: PluginBackoffPolicy
        /// Sliding window over which crashes are counted for auto-disable.
        public let crashWindow: TimeInterval
        public let timeouts: PluginHost.Timeouts

        public init(
            backoff: PluginBackoffPolicy = PluginBackoffPolicy(),
            crashWindow: TimeInterval = 60,
            timeouts: PluginHost.Timeouts = PluginHost.Timeouts()
        ) {
            self.backoff = backoff
            self.crashWindow = crashWindow
            self.timeouts = timeouts
        }
    }

    private let registry: PluginRegistry
    private let pluginsDirectory: URL
    private let scratchRoot: URL
    private let sandbox: PluginSandbox
    private let config: Configuration
    private let emitSystemAlert: @Sendable (SystemAlert) async -> Void
    private let logger: Logger

    private var hosts: [String: PluginHost] = [:]
    private var crashTimes: [String: [Date]] = [:]
    private var restarting: Set<String> = []
    private var shuttingDown = false

    public init(
        registry: PluginRegistry,
        pluginsDirectory: URL,
        scratchRoot: URL,
        sandbox: PluginSandbox,
        config: Configuration = Configuration(),
        emitSystemAlert: @escaping @Sendable (SystemAlert) async -> Void,
        logger: Logger
    ) {
        self.registry = registry
        self.pluginsDirectory = pluginsDirectory
        self.scratchRoot = scratchRoot
        self.sandbox = sandbox
        self.config = config
        self.emitSystemAlert = emitSystemAlert
        self.logger = logger
    }

    /// Launches every enabled+matching plugin. Called once at daemon boot.
    public func startEnabled() async {
        await reconcile()
    }

    /// Diffs the registry's desired set (enabled AND hash-matching) against the
    /// running hosts: starts the missing, stops the extra. Called after any
    /// plugin mutation (enable/disable/remove/reorder).
    public func reconcile() async {
        guard !shuttingDown else { return }
        let desired = await desiredPlugins()
        let desiredIDs = Set(desired.map(\.manifest.id))

        // Stop hosts no longer desired.
        for (id, host) in hosts where !desiredIDs.contains(id) {
            await host.shutdown()
            hosts[id] = nil
        }
        // Start newly desired plugins (skip ids mid-restart to avoid a double
        // launch racing the backoff path under actor reentrancy).
        for plugin in desired
        where hosts[plugin.manifest.id] == nil && !restarting.contains(plugin.manifest.id) {
            await startHost(for: plugin)
        }
    }

    /// Gracefully stops all hosts. Called at daemon shutdown.
    public func shutdownAll() async {
        shuttingDown = true
        for (_, host) in hosts {
            await host.shutdown()
        }
        hosts.removeAll()
    }

    // MARK: - Internals

    private func desiredPlugins() async -> [Plugin] {
        let plugins = (try? await registry.list()) ?? []
        return plugins.filter { $0.enabled && $0.hashMatches }
    }

    private func startHost(for plugin: Plugin) async {
        let id = plugin.manifest.id
        guard let scratch = makeScratch(for: id) else {
            logger.error("plugin scratch dir setup failed", metadata: ["id": "\(id)"])
            return
        }
        let spec = PluginLaunchSpec(
            id: id,
            executablePath: pluginsDirectory
                .appendingPathComponent(id)
                .appendingPathComponent(plugin.manifest.executable)
                .path,
            arguments: [],
            capabilities: plugin.approvedCapabilities ?? plugin.manifest.capabilities,
            configValues: [:],
            scratchDir: scratch
        )
        let host = PluginHost(
            spec: spec,
            sandbox: sandbox,
            timeouts: config.timeouts,
            logger: logger,
            onUnexpectedExit: { [weak self] crashedID in
                await self?.handleUnexpectedExit(id: crashedID)
            }
        )
        do {
            try await host.start()
            hosts[id] = host
        } catch {
            logger.warning(
                "plugin failed to start",
                metadata: ["id": "\(id)", "error": "\(error)"]
            )
            await handleUnexpectedExit(id: id)
        }
    }

    private func handleUnexpectedExit(id: String) async {
        guard !shuttingDown else { return }
        hosts[id] = nil
        // Mark as mid-restart so a concurrent reconcile() (actor reentrancy during
        // the backoff sleep below) does not double-launch this plugin. Bounded by
        // the auto-disable threshold, so nesting via startHost stays shallow.
        restarting.insert(id)
        defer { restarting.remove(id) }

        var times = (crashTimes[id] ?? []).filter { Date().timeIntervalSince($0) < config.crashWindow }
        times.append(Date())
        crashTimes[id] = times

        if config.backoff.shouldDisable(recentCrashCount: times.count) {
            logger.error(
                "plugin auto-disabled after repeated crashes",
                metadata: ["id": "\(id)", "crashes": "\(times.count)"]
            )
            _ = try? await registry.disable(id: id)
            crashTimes[id] = nil
            await emitSystemAlert(
                SystemAlert(
                    severity: .high,
                    message:
                        "Plugin '\(id)' was auto-disabled after \(times.count) crashes — re-enable it from Settings once fixed."
                )
            )
            return
        }

        let delay = config.backoff.delay(forCrashCount: times.count)
        logger.warning(
            "plugin crashed; scheduling restart",
            metadata: ["id": "\(id)", "crashes": "\(times.count)", "delay_s": "\(delay)"]
        )
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !shuttingDown else { return }
        // Restart only if still desired (a concurrent disable/remove wins).
        let desired = await desiredPlugins()
        guard let plugin = desired.first(where: { $0.manifest.id == id }) else { return }
        await startHost(for: plugin)
    }

    /// Creates `scratchRoot/<id>` and returns its canonical (realpath) URL.
    /// Seatbelt canonicalises write paths, so the profile must carry the
    /// realpath (handoff #3) — `resolvingSymlinksInPath` is not enough.
    private func makeScratch(for id: String) -> URL? {
        let dir = scratchRoot.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let canonical = dir.path.withCString { cString -> String? in
            guard let resolved = realpath(cString, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return canonical.map { URL(fileURLWithPath: $0) }
    }
}
```

> Note : `configValues` est passé vide en P2b (`[:]`). Le `Plugin` view ne porte pas `configValues` (il vit dans `PluginStateEntry`) ; un plugin avec config schema-driven est une phase ultérieure. Laisser `[:]` est conforme à la portée. Le profil applique `plugin.approvedCapabilities ?? plugin.manifest.capabilities` (l'ensemble **approuvé** par l'utilisateur à l'activation).

- [ ] **Step 2 : Écrire les tests d'intégration du manager**

Create `Tests/IntegrationTests/PluginHostManagerTests.swift` :

```swift
import IrisKit
import Logging
import XCTest

/// Exercises the manager against a real registry + the iris-test-plugin fixture,
/// through the real sandbox. Covers reconcile (start on enable, stop on disable)
/// and the crash-loop → auto-disable + SystemAlert path with shrunk timings.
final class PluginHostManagerTests: XCTestCase {
    /// Installs the fixture (built binary copied into the plugin dir) and enables
    /// it with the given mode, returning (pluginsDir, scratchRoot, registry, store).
    private func makeRegistryWithEnabledFixture(
        mode: String
    ) async throws -> (plugins: URL, scratch: URL, registry: PluginRegistry, store: ConfigStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-mgr-\(UUID().uuidString)")
        let pluginsDir = root.appendingPathComponent("plugins")
        let scratch = root.appendingPathComponent("scratch")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // Copy the built fixture into the plugin source dir as "bin", and a
        // wrapper that bakes the mode into argv is unnecessary: we encode the
        // mode in a sidecar file the fixture ignores — instead we set the mode
        // through the manifest by shipping a tiny launcher. Simplest robust path:
        // copy the fixture and select mode via a one-line shell launcher.
        let bin = source.appendingPathComponent("bin")
        try FileManager.default.copyItem(at: ExecutableLocator.testPlugin, to: bin)
        // Launcher script that execs the fixture with the chosen mode.
        let launcher = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexec \"$(dirname \"$0\")/bin\" \(mode)\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let manifest = """
            { "id": "test.mgr.plugin", "name": "Mgr Fixture", "version": "1.0.0",
              "api_version": 1, "executable": "run.sh",
              "hooks": [ { "event": "on_request", "match": {}, "timeout_ms": 200 } ],
              "capabilities": { "network": [], "filesystem": [] } }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let configPath = root.appendingPathComponent("config.json")
        let store = try await ConfigStore(path: configPath)
        let registry = PluginRegistry(
            pluginsDirectory: pluginsDir, configStore: store, logger: Logger(label: "test"))
        _ = try await registry.install(from: source)
        _ = try await registry.enable(id: "test.mgr.plugin")
        return (pluginsDir, scratch, registry, store)
    }

    private func makeManager(
        plugins: URL, scratch: URL, registry: PluginRegistry,
        alerts: AlertCollector
    ) -> PluginHostManager {
        PluginHostManager(
            registry: registry,
            pluginsDirectory: plugins,
            scratchRoot: scratch,
            sandbox: PluginSandbox(shimPath: ExecutableLocator.sandboxExec),
            config: PluginHostManager.Configuration(
                backoff: PluginBackoffPolicy(initialBackoff: 0.01, maxBackoff: 0.02, crashThreshold: 5),
                crashWindow: 60,
                timeouts: PluginHost.Timeouts(initialize: 5, shutdown: 1)
            ),
            emitSystemAlert: { alert in await alerts.append(alert) },
            logger: Logger(label: "test")
        )
    }

    func testReconcileStartsThenStopsOnDisable() async throws {
        let env = try await makeRegistryWithEnabledFixture(mode: "ok")
        let alerts = AlertCollector()
        let manager = makeManager(
            plugins: env.plugins, scratch: env.scratch, registry: env.registry, alerts: alerts)

        await manager.startEnabled()
        // The fixture wrote its scratch marker during initialize → started.
        let marker = env.scratch.appendingPathComponent("test.mgr.plugin/initialized")
        try await waitUntil(timeout: 8) { FileManager.default.fileExists(atPath: marker.path) }

        _ = try await env.registry.disable(id: "test.mgr.plugin")
        await manager.reconcile()  // host should be torn down without error
        await manager.shutdownAll()
    }

    func testCrashLoopAutoDisablesAndAlerts() async throws {
        let env = try await makeRegistryWithEnabledFixture(mode: "crash")
        let alerts = AlertCollector()
        let manager = makeManager(
            plugins: env.plugins, scratch: env.scratch, registry: env.registry, alerts: alerts)

        await manager.startEnabled()
        // 5 fast crashes (10ms backoff) → auto-disable + one high SystemAlert.
        try await waitUntil(timeout: 10) { await alerts.count >= 1 }

        let info = try await env.registry.info(id: "test.mgr.plugin")
        XCTAssertFalse(info.enabled, "plugin must be auto-disabled after crash threshold")
        let alert = await alerts.first
        XCTAssertEqual(alert?.severity, .high)
        XCTAssertTrue(alert?.message.contains("test.mgr.plugin") ?? false)
        await manager.shutdownAll()
    }

    // MARK: - Helpers

    /// Thread-safe alert sink usable as a `@Sendable` closure target.
    actor AlertCollector {
        private(set) var alerts: [SystemAlert] = []
        func append(_ alert: SystemAlert) { alerts.append(alert) }
        var count: Int { alerts.count }
        var first: SystemAlert? { alerts.first }
    }

    /// Bounded async poll (no Thread.sleep). Mirrors the P2a test polling helper.
    private func waitUntil(
        timeout: TimeInterval, _ condition: @Sendable () async -> Bool
    ) async throws {
        let steps = max(1, Int(timeout / 0.05))
        for _ in 0..<steps {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
```

> **Sandbox + launcher script :** la fixture est lancée via un `run.sh` qui `exec` le binaire avec le mode. Sous le profil deny-default, `process-exec*` et `file-read*` sont autorisés → `/bin/sh` lit et exec le binaire (prouvé en P2a : `/bin/sh -c` tourne sous le profil). Le `run.sh` est dans le dossier plugin (lecture OK). `executable: "run.sh"` est un composant de chemin sûr (validé par `PluginManifest.validate`).

- [ ] **Step 3 : Lancer les tests du manager**

Run: `swift test --filter PluginHostManagerTests 2>&1 | tail -30`
Expected: PASS (2 tests). **Si `testReconcileStartsThenStopsOnDisable` timeout sur le marqueur** : le plugin n'a pas démarré — vérifier la résolution de `executablePath` (`pluginsDir/<id>/run.sh`) et que `run.sh` est exécutable + que `dirname`/`bin` résout. **Si `testCrashLoopAutoDisablesAndAlerts` n'émet jamais d'alerte** : vérifier que `onUnexpectedExit` est bien appelé (la fixture en mode `crash` sort 3 immédiatement → `terminationHandler` → `handleUnexpectedExit`) et que le seuil (5) est atteint avant le timeout (backoff 10ms × ~5).

- [ ] **Step 4 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginHostManager.swift \
        Tests/IntegrationTests/PluginHostManagerTests.swift
git commit -m "feat(plugins): PluginHostManager — reconcile, backoff, auto-disable + SystemAlert"
```

---

## Task 7 : Câblage `Daemon.swift` + `AdminDispatcher` + `App.swift`

**Files:**
- Modify: `Sources/IrisKit/IPC/AdminDispatcher.swift`
- Modify: `Sources/irisd/Daemon.swift`
- Modify: `Sources/irisd/App.swift`
- Test: `Tests/IntegrationTests/PluginDaemonWiringTests.swift`

- [ ] **Step 1 : Ajouter `onPluginsChanged` à `AdminDispatcher`**

Dans `Sources/IrisKit/IPC/AdminDispatcher.swift` :

(a) Après la propriété `public let onConfigReload: ...` (vers la ligne 28), ajouter :

```swift
    /// Called after any plugin mutation so the host manager can reconcile the
    /// running set against the persisted enabled set.
    public let onPluginsChanged: @Sendable () async -> Void
```

(b) Dans `init`, ajouter le paramètre (après `onConfigReload:`'s default block, avant `logger:`) :

```swift
        onPluginsChanged: @escaping @Sendable () async -> Void = {},
```

et l'assignation dans le corps (après `self.onConfigReload = onConfigReload`) :

```swift
        self.onPluginsChanged = onPluginsChanged
```

(c) Dans le `switch` des méthodes plugin, appeler `onPluginsChanged()` après les mutations. Remplacer les 4 `case` `.pluginEnable`/`.pluginDisable`/`.pluginRemove`/`.pluginReorder` par des versions qui notifient :

```swift
        case .pluginEnable:
            let p = try Self.decode(PluginIdParams.self, from: params)
            let view = try await pluginRegistry.enable(id: p.id)
            await onPluginsChanged()
            return try JSONValue.encoding(view)
        case .pluginDisable:
            let p = try Self.decode(PluginIdParams.self, from: params)
            let view = try await pluginRegistry.disable(id: p.id)
            await onPluginsChanged()
            return try JSONValue.encoding(view)
        case .pluginRemove:
            let p = try Self.decode(PluginIdParams.self, from: params)
            try await pluginRegistry.remove(id: p.id)
            await onPluginsChanged()
            return try JSONValue.encoding(PluginRemovedResult(removed: true))
        case .pluginReorder:
            let p = try Self.decode(PluginReorderParams.self, from: params)
            let views = try await pluginRegistry.reorder(id: p.id, to: p.index)
            await onPluginsChanged()
            return try JSONValue.encoding(views)
```

> `pluginInstall` n'appelle PAS `onPluginsChanged` : l'install crée une entrée **disabled**, rien à lancer. (Optionnel mais inutile ; rester minimal.)

- [ ] **Step 2 : Câbler le manager dans `Daemon.swift`**

Dans `Sources/irisd/Daemon.swift` :

(a) Ajouter deux paramètres à `init` (après `pluginsDirectory: URL,`) :

```swift
        sandboxExecPath: URL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("iris-sandbox-exec")
            ?? URL(fileURLWithPath: "/usr/local/bin/iris-sandbox-exec"),
        scratchRoot: URL = URL(
            fileURLWithPath: ("~/Library/Application Support/iris/plugin-scratch" as NSString)
                .expandingTildeInPath
        ),
```

(b) Ajouter une propriété stockée près de `private let proxy: ProxyServer` :

```swift
    private let pluginHostManager: PluginHostManager
```

(c) Après la construction de `pluginRegistry` (vers ligne 153-157), construire le manager (il référence `proxy` pour émettre l'alerte) :

```swift
        let pluginHostManager = PluginHostManager(
            registry: pluginRegistry,
            pluginsDirectory: pluginsDirectory,
            scratchRoot: scratchRoot,
            sandbox: PluginSandbox(shimPath: sandboxExecPath),
            emitSystemAlert: { [proxy] alert in
                await proxy.eventRing.append(
                    Event(
                        timestamp: Date(),
                        kind: .systemAlert,
                        host: "plugin",
                        method: "-",
                        path: "-",
                        systemAlert: alert
                    )
                )
            },
            logger: logger
        )
        self.pluginHostManager = pluginHostManager
```

(d) Dans la construction d'`AdminDispatcher` (vers ligne 158-180), ajouter l'argument `onPluginsChanged` (après `onConfigReload:`) :

```swift
            onPluginsChanged: { [pluginHostManager] in
                await pluginHostManager.reconcile()
            },
```

(e) Dans `run()`, après `_ = try await eventsServer.start()` (et avant le log `irisd ready`), démarrer les plugins activés :

```swift
        await pluginHostManager.startEnabled()
```

(f) Dans `stop()`, avant `try? await proxy.stop()`, arrêter les plugins :

```swift
        await pluginHostManager.shutdownAll()
```

- [ ] **Step 3 : Résoudre le shim dans `App.swift`**

Le défaut de `sandboxExecPath` (basé sur `Bundle.main.executableURL`) résout déjà le shim à côté d'`irisd` en production. **Aucune modification n'est nécessaire dans `App.swift`** si on accepte le défaut. Vérifier que le `Daemon(...)` dans `App.swift` (vers ligne 107-114) compile inchangé (les nouveaux params ont des défauts). Si tu veux être explicite, ajouter au call site `App.swift` :

```swift
            // (optionnel) pluginsDirectory déjà passé ; sandboxExecPath/scratchRoot
            // utilisent leurs défauts (shim à côté de l'exécutable, scratch sous
            // ~/Library/Application Support/iris/plugin-scratch).
```

Laisser les défauts est suffisant et préféré (YAGNI). Ne rien changer si le build passe.

- [ ] **Step 4 : Build complet**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`. **Si erreur « extra argument 'onPluginsChanged' »** dans un test ou call site existant d'`AdminDispatcher` : le param a un défaut `{}`, donc les call sites existants compilent — vérifier qu'aucun appel positionnel ne casse l'ordre.

- [ ] **Step 5 : Écrire le test de câblage bout-en-bout**

Create `Tests/IntegrationTests/PluginDaemonWiringTests.swift` :

```swift
import IrisKit
import Logging
import XCTest

/// Boots a real Daemon with an installed+enabled fixture plugin and asserts the
/// host manager starts it at boot: the fixture writes a scratch marker during
/// the initialize handshake. Proves Daemon → PluginHostManager → PluginHost →
/// sandbox → NDJSON initialize end-to-end.
final class PluginDaemonWiringTests: XCTestCase {
    func testDaemonStartsEnabledPluginAtBoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-wire-\(UUID().uuidString)")
        let pluginsDir = root.appendingPathComponent("plugins")
        let scratch = root.appendingPathComponent("scratch")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let bin = source.appendingPathComponent("bin")
        try FileManager.default.copyItem(at: ExecutableLocator.testPlugin, to: bin)
        let launcher = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexec \"$(dirname \"$0\")/bin\" ok\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let manifest = """
            { "id": "test.wire.plugin", "name": "Wire Fixture", "version": "1.0.0",
              "api_version": 1, "executable": "run.sh",
              "hooks": [ { "event": "on_request", "match": {}, "timeout_ms": 200 } ],
              "capabilities": { "network": [], "filesystem": [] } }
            """
        try manifest.write(
            to: source.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        // Use a free admin/listen config via in-memory CA + secrets; isolate
        // every path under `root` so nothing touches the user's real install.
        let configPath = root.appendingPathComponent("config.json")
        let store = try await ConfigStore(path: configPath)
        let registry = PluginRegistry(
            pluginsDirectory: pluginsDir, configStore: store, logger: Logger(label: "test"))
        _ = try await registry.install(from: source)
        _ = try await registry.enable(id: "test.wire.plugin")

        let daemon = try await Daemon(
            configStore: store,
            secretBackend: .inMemoryFromEnvironment,
            caBackend: .inMemory,
            caPath: root.appendingPathComponent("ca.pem"),
            pluginsDirectory: pluginsDir,
            sandboxExecPath: ExecutableLocator.sandboxExec,
            scratchRoot: scratch,
            logger: Logger(label: "test")
        )

        let runTask = Task { try await daemon.run() }
        defer { runTask.cancel() }

        let marker = scratch.appendingPathComponent("test.wire.plugin/initialized")
        var ok = false
        for _ in 0..<160 {  // up to 8s
            if FileManager.default.fileExists(atPath: marker.path) { ok = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await daemon.stop()
        XCTAssertTrue(ok, "daemon should have started the enabled plugin and run initialize")
    }
}
```

> **Pré-requis du test :** `secretBackend: .inMemoryFromEnvironment` lit les secrets depuis l'environnement (vide ici = aucun secret, suffisant — le plugin n'a pas besoin de secrets). Le port d'écoute vient de la config par défaut ; comme `ConfigStore` neuf seed les défauts, le daemon écoute sur le port par défaut. **Si un autre test/daemon occupe déjà ce port en CI**, ce test peut échouer au `proxy.start()` — dans ce cas, écrire un `config.json` initial dans `root` avec des ports libres (ex. `listen = "127.0.0.1:0"`) avant de construire le `ConfigStore`. Vérifier le comportement de bind sur port 0 ; sinon choisir des ports hauts fixes peu probables d'être pris.

- [ ] **Step 6 : Lancer le test de câblage**

Run: `swift test --filter PluginDaemonWiringTests 2>&1 | tail -30`
Expected: PASS. **Si échec au boot (`proxy.start()` lève)** : conflit de port → fixer des ports libres dans un `config.json` initial (cf. note Step 5). **Si le marqueur n'apparaît jamais** : le manager n'a pas été démarré dans `run()` (vérifier Step 2e) ou le shim n'est pas trouvé (vérifier `sandboxExecPath`).

- [ ] **Step 7 : Commit**

```bash
git add Sources/IrisKit/IPC/AdminDispatcher.swift Sources/irisd/Daemon.swift \
        Sources/irisd/App.swift Tests/IntegrationTests/PluginDaemonWiringTests.swift
git commit -m "feat(plugins): câblage Daemon ↔ PluginHostManager (boot/reconcile/shutdown)"
```

---

## Task 8 : Lint, build/test complets, mise à jour du design doc

**Files:**
- Modify: `docs/plugins-design.md` (§8/§14 — décisions P2b figées)

- [ ] **Step 1 : Mettre à jour le design doc**

Dans `docs/plugins-design.md`, §14 #5, remplacer la ligne :

```
5. **Politique de restart/backoff** et seuil d'auto-désactivation après crashes répétés. *(détail P2)*
```

par :

```
5. **Politique de restart/backoff** et seuil d'auto-désactivation — ✅ **tranché P2b** : backoff
   exponentiel `initial=250 ms ×2`, plafonné à `30 s` ; fenêtre glissante de crashes de `60 s` ;
   auto-désactivation après `5` crashes dans la fenêtre (`registry.disable` + `SystemAlert` high).
   Valeurs injectables (`PluginBackoffPolicy` / `PluginHostManager.Configuration`).
```

Dans §8, après le paragraphe `initialize`, ajouter une phrase sur le `scratch_dir` :

```
> P2b : `initialize` porte aussi `scratch_dir` (chemin **canonique** realpath du scratch privé du
> plugin) ; le cwd du process est positionné sur ce dossier. Le sandbox n'autorise l'écriture que là.
```

Dans la section « Découvertes durant l'implémentation P2a », point 5 (localisation du shim), noter qu'il est résolu :

```
5. **Localisation du shim** — ✅ résolu P2b : `Daemon` reçoit `sandboxExecPath`, défaut =
   `Bundle.main.executableURL`/`iris-sandbox-exec` (à côté de l'exécutable daemon). Le `.pkg` qui
   embarque + signe le shim à côté d'`irisd` reste un suivi Phase 9.
```

- [ ] **Step 2 : Formater**

Run: `swift format lint --strict --recursive Sources Tests Package.swift 2>&1 | tail -20`
Expected: aucune violation (le `.c` et le `.swift` de fixture sont couverts ; `main.swift` de fixture doit aussi passer). **Si violations** : `swift format --in-place --recursive <fichiers>` puis re-commit `chore(format)`.

- [ ] **Step 3 : Build complet**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (5 produits + cibles `iris-test-plugin`).

- [ ] **Step 4 : Suite complète (non-régression)**

Run: `swift test 2>&1 | tail -20`
Expected: tous les tests passent (les 583 de P2a + les nouveaux P2b). Aucun test ignoré. **Compter** les nouvelles classes : `PluginRPCTests` (4), `PluginBackoffPolicyTests` (4), `PluginLineReaderTests` (1), `PluginHostTests` (1), `PluginHostManagerTests` (2), `PluginDaemonWiringTests` (1).

- [ ] **Step 5 : Vérifier la fixture est bâtie**

Run: `ls .build/debug/iris-test-plugin && file .build/debug/iris-test-plugin`
Expected: le binaire existe, `Mach-O ... executable`.

- [ ] **Step 6 : Commit final**

```bash
git add docs/plugins-design.md
git commit -m "docs(plugins): figer décisions P2b (backoff, scratch_dir, shim résolu)"
```

---

## Self-Review (effectuée à l'écriture)

- **Couverture spec / design :**
  - §8 « process chaud, NDJSON, initialize/shutdown » → Tasks 1 (types), 5 (host handshake), 6/7 (lifecycle). `onRequest` explicitement hors-P2b.
  - §8 « crash → restart backoff ; après N → auto-désactivation + SystemAlert » → Tasks 2 (policy), 6 (manager), 7 (émission via `proxy.eventRing`).
  - §14 #5 (politique backoff/seuil) → tranché Task 2 + figé Task 8.
  - Handoff P2a #3 (scratch realpath) → `makeScratch` (Task 6) + `realpath()` (Task 5 test) + assertion marqueur.
  - Handoff P2a #5 (localisation shim) → `sandboxExecPath` (Task 7) + figé Task 8.
  - Câblage `Daemon.swift` + `onPluginsChanged` → Task 7. Invariant §3 (pas de donnée requête au plugin) respecté : `initialize` ne porte que `config_values`/capabilities/`scratch_dir`.
- **Placeholders :** aucun — tout le code Swift/test est complet. La sélection de mode de la fixture passe par le binaire (défaut `ok`, Task 5) ou un launcher `run.sh` installé (Task 6), sans champ supplémentaire sur `PluginLaunchSpec`.
- **Cohérence des types :**
  - `PluginRPC.encodeRequest(method:params:id:)` / `encodeNotification(method:)` / `decodeResponse(_:)` (Task 1) ↔ utilisés en Task 5.
  - `PluginBackoffPolicy(initialBackoff:maxBackoff:crashThreshold:)` + `delay(forCrashCount:)` + `shouldDisable(recentCrashCount:)` (Task 2) ↔ Task 6 + tests.
  - `PluginLineReader(fileDescriptor:onLine:onEOF:)` + `start()`/`stop()` (Task 4) ↔ Task 5.
  - `PluginLaunchSpec(id:executablePath:capabilities:configValues:scratchDir:)` (Task 5) ↔ Task 6 `startHost`.
  - `PluginHost(spec:sandbox:timeouts:logger:onUnexpectedExit:)` + `start()`/`shutdown()` (Task 5) ↔ Task 6.
  - `PluginSandbox.launch(executable:arguments:profile:currentDirectory:standardInput:standardOutput:standardError:)` (Task 3) ↔ Task 5 `start()`.
  - `PluginHostManager(registry:pluginsDirectory:scratchRoot:sandbox:config:emitSystemAlert:logger:)` + `startEnabled()`/`reconcile()`/`shutdownAll()` (Task 6) ↔ Task 7 Daemon.
  - `AdminDispatcher(... onPluginsChanged:)` (Task 7) ↔ appelé après enable/disable/remove/reorder ; défaut `{}` préserve les call sites/tests existants.
  - `Daemon(... pluginsDirectory: sandboxExecPath: scratchRoot:)` (Task 7) ↔ App.swift (défauts) + test de câblage (injection).
  - `Event(timestamp:kind:host:method:path:systemAlert:)` + `SystemAlert(severity:message:)` ↔ signatures réelles (`Models/Event.swift`, `Models/Alert.swift`).
- **Risque résiduel connu :**
  - Conflit de port possible dans `PluginDaemonWiringTests` si la config par défaut bind un port déjà pris en CI (mitigation documentée Task 7 Step 5).
  - `FileHandle.write` synchrone sur stdin : OK pour des messages courts (`initialize`/`shutdown`) ; les gros bodies `onRequest` de P3 demanderont un write asynchrone/chunké (noté hors-P2b).
  - Réseau-allow SBPL toujours `PROVISIONAL` (aucun plugin réseau exercé en P2b) — inchangé depuis P2a.
