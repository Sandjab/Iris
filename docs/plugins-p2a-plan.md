# Plugins P2a — Socle sandbox (exec-shim + profil SBPL) — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dé-risquer et poser le socle de confinement des plugins IRIS : un exec-shim C qui applique un profil Seatbelt à un binaire tiers, et un générateur de profil SBPL deny-by-default dérivé des `PluginCapabilities`.

**Architecture :** Le daemon ne charge aucun code de plugin in-process. Pour confiner un exécutable tiers (langage libre, possiblement non signé), on l'enrobe d'un mini-lanceur **qu'on possède** (`iris-sandbox-exec`, cible C) : il lit un profil SBPL depuis un fichier, l'applique via `sandbox_init_with_parameters` (SPI Seatbelt, le chemin de Chromium — cf. `docs/plugins-design.md §6` et la note de décision du spike), puis `execv()` le plugin (la sandbox est héritée à travers `exec`). Le profil est généré côté Swift (`PluginSandboxProfile`, pur et testable) à partir des capabilities approuvées : tout interdit par défaut, lecture FS large (pour que `dyld` démarre un binaire dynamique), écriture FS interdite hors scratch, réseau interdit hors endpoints accordés. **Invariant §3 inchangé** : la sandbox protège la confidentialité des bodies de requête contre un plugin malveillant ; elle ne voit jamais les secrets et le scan exfil d'Iris tourne toujours après les plugins.

**Tech Stack :** Swift 5.9 / SwiftPM (cible C `executableTarget`), Seatbelt SBPL + `sandbox_init_with_parameters` (SPI déclarée en `extern`), `Foundation.Process` (précédent : `CATrustStore`), XCTest, NIO (listener éphémère pour le test réseau).

**Conventions repo (rappel) :**
- Tous les commits : préfixe conventional + trailer `Claude-Session:` (CLAUDE.md §8). Les exemples ci-dessous omettent le trailer pour la lisibilité — l'ajouter à chaque commit.
- `swift-format` : 120 col, 4 espaces, **1 argument par ligne** sur les appels multi-args.
- `-strict-concurrency=complete` partout sauf la cible C.
- Tests : **XCTest uniquement** (pas de swift-testing). Unitaires → `Tests/IrisKitTests/` ; smoke spawnant des process → `Tests/IntegrationTests/`.

**Portée P2a (ce qui N'est PAS fait ici, → P2b) :** aucun process « chaud », aucune IPC NDJSON, aucun `initialize`/`shutdown`, aucun câblage dans `Daemon.swift`, aucune UI. P2a lance des process **éphémères** uniquement pour prouver l'enforcement. Le seam `PluginSandboxing` (protocole + mock) est introduit en P2b quand le `PluginHostManager` en a besoin (YAGNI).

---

## File Structure

| Fichier | Création/Modif | Responsabilité |
|---|---|---|
| `Sources/iris-sandbox-exec/main.c` | Create | Exec-shim C : lit le profil, `sandbox_init_with_parameters`, `execv`. |
| `Package.swift` | Modify | + product + cible C `iris-sandbox-exec` ; + dépendance de `IntegrationTests`. |
| `Sources/IrisKit/Plugins/PluginSandboxProfile.swift` | Create | Générateur SBPL pur depuis `PluginCapabilities` + scratch dir. |
| `Sources/IrisKit/Plugins/PluginSandbox.swift` | Create | `PluginSandbox.launch(...)` : écrit le profil en temp, spawn le shim via `Process`. |
| `Tests/IrisKitTests/PluginSandboxProfileTests.swift` | Create | Tests unitaires du générateur. |
| `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift` | Modify | + `sandboxExec` (localise le binaire shim compilé). |
| `Tests/IntegrationTests/PluginShimSmokeTests.swift` | Create | Smoke shim : usage error + binaire normal sous profil permissif (dé-risque l'API). |
| `Tests/IntegrationTests/PluginSandboxEnforcementTests.swift` | Create | Enforcement : binaire normal sous profil réel, write hors scratch refusé/scratch OK, réseau refusé (avec contrôle). |

---

## Task 1 : Exec-shim C + cible Package + localisation test

**Files:**
- Create: `Sources/iris-sandbox-exec/main.c`
- Modify: `Package.swift` (products, targets, IntegrationTests deps)
- Modify: `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift`
- Test: `Tests/IntegrationTests/PluginShimSmokeTests.swift`

- [ ] **Step 1 : Écrire le shim C**

Create `Sources/iris-sandbox-exec/main.c` :

```c
// iris-sandbox-exec — minimal Seatbelt exec-shim for IRIS plugins.
//
// Usage: iris-sandbox-exec <profile-path> <plugin-executable> [args...]
//
// Reads an SBPL profile from <profile-path>, applies it to the current
// process via sandbox_init_with_parameters (Seatbelt SPI — the same path
// Chromium uses; see docs/plugins-design.md §6), then execv()s the plugin so
// the sandbox is inherited across exec. Deny-by-default lives in the profile,
// not here.
//
// Exit codes are chosen to be distinct from typical child codes:
//   64 usage, 70 internal (profile read / sandbox apply), 71 exec failure.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Seatbelt SPI — not in a public header; declared here as Chromium does.
// flags == 0 means `profile` is a raw SBPL string (SANDBOX_STRING).
extern int sandbox_init_with_parameters(const char *profile,
                                        uint64_t flags,
                                        const char *const parameters[],
                                        char **errorbuf);
extern void sandbox_free_error(char *errorbuf);

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = malloc((size_t)size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[n] = '\0';
    return buf;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: iris-sandbox-exec <profile-path> <executable> [args...]\n");
        return 64;
    }
    const char *profile_path = argv[1];
    const char *executable = argv[2];

    char *profile = read_file(profile_path);
    if (!profile) {
        fprintf(stderr, "iris-sandbox-exec: cannot read profile '%s': %s\n",
                profile_path, strerror(errno));
        return 70;
    }

    char *errbuf = NULL;
    int rc = sandbox_init_with_parameters(profile, 0, NULL, &errbuf);
    free(profile);
    if (rc != 0) {
        fprintf(stderr, "iris-sandbox-exec: sandbox_init failed: %s\n",
                errbuf ? errbuf : "(unknown)");
        if (errbuf) sandbox_free_error(errbuf);
        return 70;
    }

    // execv inherits the sandbox. argv[2..] (NULL-terminated by the OS)
    // becomes the child's argv, so argv[2] is also the child's argv[0].
    execv(executable, &argv[2]);
    fprintf(stderr, "iris-sandbox-exec: execv '%s' failed: %s\n",
            executable, strerror(errno));
    return 71;
}
```

- [ ] **Step 2 : Déclarer la cible et le produit dans `Package.swift`**

Dans le tableau `products`, ajouter après la ligne `.executable(name: "iris", targets: ["iris"]),` :

```swift
        .executable(name: "iris-sandbox-exec", targets: ["iris-sandbox-exec"]),
```

Dans le tableau `targets`, ajouter une nouvelle cible C (pas de `swiftSettings` — c'est du C ; `-lsandbox` par sûreté au cas où le symbole ne serait pas résolu via l'umbrella libSystem) :

```swift
        .executableTarget(
            name: "iris-sandbox-exec",
            linkerSettings: [
                .linkedLibrary("sandbox")
            ]
        ),
```

Dans la cible de test `IntegrationTests`, ajouter `"iris-sandbox-exec"` à la liste `dependencies` (pour que SwiftPM compile le shim avant de lancer les tests, comme pour `iris`/`irisd`).

- [ ] **Step 3 : Ajouter le localisateur du shim**

Dans `Tests/IntegrationTests/CLISupport/ExecutableLocator.swift`, ajouter après `static var irisd: URL { url(forProduct: "irisd") }` :

```swift
    static var sandboxExec: URL { url(forProduct: "iris-sandbox-exec") }
```

- [ ] **Step 4 : Build, vérifier que le shim compile et linke**

Run: `swift build --product iris-sandbox-exec 2>&1 | tail -5`
Expected: build réussit, produit `.build/debug/iris-sandbox-exec`. **Si erreur de link sur `sandbox_init_with_parameters`** : confirmer que `.linkedLibrary("sandbox")` est bien présent ; sinon STOP et reporter (le symbole devrait être dans libSystem). **Si erreur de compile C** : corriger avant d'aller plus loin.

- [ ] **Step 5 : Écrire le smoke shim (dé-risque l'API)**

Create `Tests/IntegrationTests/PluginShimSmokeTests.swift` :

```swift
import Foundation
import XCTest

/// De-risks the deprecated Seatbelt API: proves the shim links
/// `sandbox_init_with_parameters`, applies a profile, and execs a real binary
/// whose output flows back. Uses an allow-all profile here so this test isolates
/// "does the API/plumbing work" from "is our deny-default profile workable"
/// (the latter is PluginSandboxEnforcementTests).
final class PluginShimSmokeTests: XCTestCase {
    private func runShim(_ args: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = ExecutableLocator.sandboxExec
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testUsageErrorWhenTooFewArguments() throws {
        let result = try runShim(["only-one-arg"])
        XCTAssertEqual(result.status, 64)
    }

    func testAppliesProfileAndExecsBinary() throws {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shim-smoke-\(UUID().uuidString).sb")
        try "(version 1)\n(allow default)\n".write(to: profileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        let result = try runShim([profileURL.path, "/bin/echo", "hello-from-sandbox"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(
            result.stdout.contains("hello-from-sandbox"),
            "expected echo output, got: \(result.stdout)"
        )
    }
}
```

- [ ] **Step 6 : Lancer le smoke shim**

Run: `swift test --filter PluginShimSmokeTests 2>&1 | tail -20`
Expected: PASS (2 tests). Cela prouve : le shim linke `sandbox_init_with_parameters`, applique un profil, et `execv` un binaire dont stdout revient. **Si `testAppliesProfileAndExecsBinary` échoue avec status 70** : `sandbox_init` rejette le profil — vérifier la syntaxe `(version 1)\n(allow default)\n`. **Si status 71** : `execv` échoue — vérifier que `/bin/echo` existe.

- [ ] **Step 7 : Commit**

```bash
git add Sources/iris-sandbox-exec/main.c Package.swift \
        Tests/IntegrationTests/CLISupport/ExecutableLocator.swift \
        Tests/IntegrationTests/PluginShimSmokeTests.swift
git commit -m "feat(plugins): exec-shim Seatbelt (iris-sandbox-exec) + smoke API"
```

---

## Task 2 : Générateur de profil SBPL (`PluginSandboxProfile`)

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginSandboxProfile.swift`
- Test: `Tests/IrisKitTests/PluginSandboxProfileTests.swift`

- [ ] **Step 1 : Écrire les tests d'abord**

Create `Tests/IrisKitTests/PluginSandboxProfileTests.swift` :

```swift
import XCTest
@testable import IrisKit

final class PluginSandboxProfileTests: XCTestCase {
    func testDeniesByDefaultAndAllowsScratchWrite() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: "/tmp/iris-scratch/foo"
        )
        XCTAssertTrue(profile.contains("(version 1)"))
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(allow process-exec*)"))
        XCTAssertTrue(profile.contains("(allow file-read*)"))
        XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"/tmp/iris-scratch/foo\"))"))
        XCTAssertTrue(profile.contains("(deny network*)"))
    }

    func testNoNetworkAllowLinesWhenCapabilityEmpty() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(network: [], filesystem: []),
            scratchDir: "/tmp/s"
        )
        XCTAssertFalse(profile.contains("network-outbound"))
    }

    func testNetworkAllowLinesWhenGranted() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(network: ["api.example.com:443"], filesystem: []),
            scratchDir: "/tmp/s"
        )
        XCTAssertTrue(
            profile.contains("(allow network-outbound (remote ip \"api.example.com:443\"))")
        )
    }

    func testEscapesScratchPath() {
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: "/tmp/a\"b\\c"
        )
        XCTAssertTrue(profile.contains("(subpath \"/tmp/a\\\"b\\\\c\")"))
    }
}
```

- [ ] **Step 2 : Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter PluginSandboxProfileTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'PluginSandboxProfile' in scope`.

- [ ] **Step 3 : Implémenter le générateur**

Create `Sources/IrisKit/Plugins/PluginSandboxProfile.swift` :

```swift
import Foundation

/// Generates a Seatbelt (SBPL) profile string from a plugin's capabilities.
/// Pure and deterministic — no I/O, fully unit-testable.
///
/// v1 model (cf. docs/plugins-design.md §6):
/// - deny by default;
/// - allow process exec/fork and broad file *read* so a dynamically linked
///   binary can start via dyld (read confidentiality is out of scope v1 —
///   the network deny-by-default below closes the exfil channel);
/// - deny file *write* except the plugin's private scratch dir;
/// - deny network by default; allow only the granted `network` endpoints.
public enum PluginSandboxProfile {
    public static func generate(capabilities: PluginCapabilities, scratchDir: String) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process-fork)",
            "(allow process-exec*)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read*)",
            "(deny file-write*)",
            "(allow file-write* (subpath \(sbplString(scratchDir))))",
            "(deny network*)",
        ]
        for endpoint in capabilities.network {
            lines.append("(allow network-outbound (remote ip \(sbplString(endpoint))))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a string as an SBPL string literal, escaping backslashes and quotes.
    static func sbplString(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
```

- [ ] **Step 4 : Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter PluginSandboxProfileTests 2>&1 | tail -10`
Expected: PASS (4 tests).

- [ ] **Step 5 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginSandboxProfile.swift \
        Tests/IrisKitTests/PluginSandboxProfileTests.swift
git commit -m "feat(plugins): générateur de profil SBPL deny-by-default"
```

---

## Task 3 : Lanceur Swift (`PluginSandbox`) + intégration profil réel

**Files:**
- Create: `Sources/IrisKit/Plugins/PluginSandbox.swift`
- Test: `Tests/IntegrationTests/PluginSandboxEnforcementTests.swift` (créé ici, première méthode ; complété en Task 4)

- [ ] **Step 1 : Implémenter le lanceur**

Create `Sources/IrisKit/Plugins/PluginSandbox.swift` :

```swift
import Foundation

/// Launches a plugin executable confined by a generated Seatbelt profile, via
/// the `iris-sandbox-exec` shim. P2a: spawn + caller waits/owns the process.
/// P2b wraps this in the warm-process lifecycle with NDJSON IPC pipes.
public struct PluginSandbox: Sendable {
    /// Path to the `iris-sandbox-exec` binary. Production resolves it next to
    /// the running daemon executable; tests inject the built-products path.
    let shimPath: URL

    public init(shimPath: URL) {
        self.shimPath = shimPath
    }

    /// Writes `profile` to a temp file and spawns the shim, which applies the
    /// sandbox then execs `executable`. The temp profile file is removed when
    /// the process terminates. The caller owns the returned `Process`.
    public func launch(
        executable: String,
        arguments: [String] = [],
        profile: String,
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
        if let standardOutput {
            process.standardOutput = standardOutput
        }
        if let standardError {
            process.standardError = standardError
        }
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: profileURL)
        }
        try process.run()
        return process
    }
}
```

- [ ] **Step 2 : Écrire le test « le profil réel laisse démarrer un binaire »**

Create `Tests/IntegrationTests/PluginSandboxEnforcementTests.swift` :

```swift
import IrisKit
import NIOCore
import NIOPosix
import XCTest

/// Proves the *generated* deny-default profile (a) is not so tight that a
/// dynamically linked binary fails to start, and (b) actually enforces the
/// write/network restrictions. Each test runs an ephemeral child through the
/// real PluginSandbox + iris-sandbox-exec shim.
final class PluginSandboxEnforcementTests: XCTestCase {
    private func sandbox() -> PluginSandbox {
        PluginSandbox(shimPath: ExecutableLocator.sandboxExec)
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRealProfileStillLetsBinaryRun() throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )
        let out = Pipe()
        let process = try sandbox().launch(
            executable: "/bin/echo",
            arguments: ["alive"],
            profile: profile,
            standardOutput: out
        )
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("alive"))
    }
}
```

- [ ] **Step 3 : Lancer le test**

Run: `swift test --filter PluginSandboxEnforcementTests/testRealProfileStillLetsBinaryRun 2>&1 | tail -20`
Expected: PASS. **Si status ≠ 0 (binaire bloqué au démarrage)** : le profil deny-default est trop serré pour `dyld`. Ajouter les règles manquantes dans `PluginSandboxProfile.generate` (candidats fréquents : `(allow file-read-metadata)`, `(allow sysctl-read)` déjà présent, `(allow mach-lookup)` déjà présent). Itérer jusqu'au PASS, puis ajuster le test unitaire de Task 2 si une ligne est ajoutée. **C'est la validation empirique clé de la décision de spike.**

- [ ] **Step 4 : Commit**

```bash
git add Sources/IrisKit/Plugins/PluginSandbox.swift \
        Tests/IntegrationTests/PluginSandboxEnforcementTests.swift
git commit -m "feat(plugins): lanceur PluginSandbox + smoke binaire sous profil réel"
```

---

## Task 4 : Smoke d'enforcement (write hors scratch / réseau)

**Files:**
- Modify: `Tests/IntegrationTests/PluginSandboxEnforcementTests.swift`

- [ ] **Step 1 : Ajouter le test d'écriture FS (hors scratch refusée, scratch OK)**

Dans `PluginSandboxEnforcementTests`, ajouter cette méthode :

```swift
    func testFileWriteDeniedOutsideScratchAllowedInside() throws {
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )

        // (a) write OUTSIDE scratch → denied → sh exits non-zero, file absent.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        let denied = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo x > \(outside.path)"],
            profile: profile
        )
        denied.waitUntilExit()
        XCTAssertNotEqual(denied.terminationStatus, 0, "write outside scratch must be denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))

        // (b) write INSIDE scratch → allowed → sh exits 0, file present.
        let inside = scratch.appendingPathComponent("ok.txt")
        let allowed = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", "echo x > \(inside.path)"],
            profile: profile
        )
        allowed.waitUntilExit()
        XCTAssertEqual(allowed.terminationStatus, 0, "write inside scratch must be allowed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }
```

- [ ] **Step 2 : Ajouter le test réseau (refusé sous sandbox, autorisé sans — contrôle)**

Dans `PluginSandboxEnforcementTests`, ajouter cette méthode. Elle ouvre un listener TCP éphémère, prouve d'abord que la sonde `/dev/tcp` fonctionne **sans** sandbox (contrôle), puis qu'elle est bloquée **avec** :

```swift
    func testNetworkDeniedByDefault() throws {
        // Ephemeral TCP listener so the connect probe has a real peer.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { try? server.close().wait() }
        guard let port = server.localAddress?.port else {
            return XCTFail("listener has no port")
        }
        let probe = "exec 3<>/dev/tcp/127.0.0.1/\(port)"

        // Control: NO sandbox → the /dev/tcp connect succeeds (status 0).
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sh")
        control.arguments = ["-c", probe]
        try control.run()
        control.waitUntilExit()
        XCTAssertEqual(control.terminationStatus, 0, "control: connect should work without sandbox")

        // Sandboxed: deny network* → connect blocked → status non-zero.
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let profile = PluginSandboxProfile.generate(
            capabilities: PluginCapabilities(),
            scratchDir: scratch.path
        )
        let blocked = try sandbox().launch(
            executable: "/bin/sh",
            arguments: ["-c", probe],
            profile: profile
        )
        blocked.waitUntilExit()
        XCTAssertNotEqual(blocked.terminationStatus, 0, "sandbox must deny outbound network")
    }
```

- [ ] **Step 3 : Lancer toute la classe d'enforcement**

Run: `swift test --filter PluginSandboxEnforcementTests 2>&1 | tail -25`
Expected: PASS (3 tests). **Si `testNetworkDeniedByDefault` échoue au contrôle (status ≠ 0 sans sandbox)** : `/bin/sh` n'a pas pu ouvrir `/dev/tcp` indépendamment de la sandbox — le test n'est pas significatif ; vérifier que le listener est bien lié. **Si la branche sandboxée passe (status 0)** : le réseau n'est PAS bloqué → STOP, le profil ou la syntaxe `(deny network*)` est en cause — investiguer avant de continuer (c'est une propriété de sécurité bloquante).

- [ ] **Step 4 : Commit**

```bash
git add Tests/IntegrationTests/PluginSandboxEnforcementTests.swift
git commit -m "test(plugins): enforcement sandbox — write hors scratch + réseau refusés"
```

---

## Task 5 : Lint, build/test complets, vérification finale

**Files:** aucun nouveau (vérification globale).

- [ ] **Step 1 : Formater**

Run: `swift format lint --recursive --strict Sources/iris-sandbox-exec Sources/IrisKit/Plugins Tests/IrisKitTests Tests/IntegrationTests 2>&1 | tail -20`
Expected: aucune violation (le `.c` est ignoré par swift-format). Si violations : `swift format --in-place --recursive <fichiers>` puis re-commit `chore(format)`.

- [ ] **Step 2 : Build complet**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (les 5 produits, dont `iris-sandbox-exec`).

- [ ] **Step 3 : Suite de tests complète (non-régression)**

Run: `swift test 2>&1 | tail -15`
Expected: tous les tests passent (les ~574 existants + les nouveaux). Aucun test ignoré.

- [ ] **Step 4 : Vérifier le compte de produits**

Run: `ls .build/debug/iris-sandbox-exec && file .build/debug/iris-sandbox-exec`
Expected: le binaire existe, `Mach-O ... executable`.

- [ ] **Step 5 : Commit final si nécessaire (format) — sinon rien**

Si Step 1 a produit des changements non commités :

```bash
git add -A && git commit -m "chore(format): swift-format sur le socle sandbox P2a"
```

---

## Self-Review (effectuée à l'écriture)

- **Couverture spec :** §6 du design (sandbox = Seatbelt + exec-shim ; deny-default ; spawn sans entitlement) → Tasks 1-4. La sous-décision « `sandbox_init` public vs `sandbox_init_with_parameters` SPI » est tranchée empiriquement : on part sur le SPI (chemin Chromium), validé par les Tasks 1/3/4 ; si le link échoue, Task 1 Step 4 le signale. P2b (lifecycle/IPC/câblage) explicitement hors périmètre.
- **Placeholders :** aucun — tout le code C/Swift/test est complet.
- **Cohérence des types :** `PluginSandboxProfile.generate(capabilities:scratchDir:) -> String` (Task 2) ↔ appelé identiquement en Tasks 3-4. `PluginSandbox.init(shimPath:)` + `launch(executable:arguments:profile:standardOutput:standardError:)` (Task 3) ↔ appels en Tasks 3-4. `ExecutableLocator.sandboxExec` (Task 1) ↔ utilisé en Tasks 1/3/4. `PluginCapabilities(network:filesystem:)` conforme à la signature P1 réelle (`Sources/IrisKit/Plugins/PluginManifest.swift:185`).
- **Risque résiduel connu :** la syntaxe SBPL exacte du filtre réseau `(remote ip "host:port")` n'est pas exercée en allow (aucun plugin ne fait d'appel sortant en P2a) ; seul le **deny-by-default** est prouvé (Task 4). L'enforcement du allow-host sera validé quand un plugin réseau existera (phase ultérieure). Documenté dans `PluginSandboxProfile`.
