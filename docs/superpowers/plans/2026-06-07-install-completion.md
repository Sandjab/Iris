# Compléter l'installation (CLI `iris` + config terminal) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Livrer réellement la commande `iris` dans `/usr/local/bin`, permettre à Iris de configurer le terminal de façon réversible et avec consentement, et corriger la doc qui décrit une topologie obsolète.

**Architecture:** Un module IrisKit `ShellProfileConfigurator` (logique pure de bloc balisé + couche I/O) est la source unique de vérité. Il est exposé en CLI (`iris shell install/uninstall/status`, interactif) et dans l'app via un seam testable `ShellConfiguring` (réplique de `CATrustInstalling`) appelé par `AppModel` puis affiché dans l'onglet Settings. Le packaging ajoute un composant `.pkg` qui installe `iris` dans `/usr/local/bin`. La doc est corrigée.

**Tech Stack:** Swift 5.9+, SwiftPM, swift-argument-parser, XCTest, SwiftUI/AppKit, `pkgbuild`/`productbuild`.

**Spec:** `docs/superpowers/specs/2026-06-07-install-completion-design.md`

---

## Conventions de ce plan

- Build : `swift build`. Tests ciblés : `swift test --filter <Suite>/<test>`.
- Framework de test : **XCTest** (le repo n'utilise pas swift-testing : 62 fichiers XCTest, 0 Testing).
- Lint avant chaque commit : `swift-format` (cf. `CLAUDE.md §5`). Commande projet :
  `swift format lint -r Sources Tests` (ou `swift-format` selon l'install).
- Commits : conventional, un par tâche minimum.

---

## Task 1 : `ShellProfileConfigurator` — logique pure du bloc balisé

**Files:**
- Create: `Sources/IrisKit/Shell/ShellProfileConfigurator.swift`
- Test: `Tests/IrisKitTests/ShellProfileConfiguratorTests.swift`

- [ ] **Step 1 : Écrire les tests de logique pure (échec attendu)**

```swift
// Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
import XCTest

@testable import IrisKit

final class ShellProfileConfiguratorTests: XCTestCase {
    private func blockCount(in content: String) -> Int {
        content.components(separatedBy: "\n")
            .filter { $0 == ShellProfileConfigurator.beginMarker }
            .count
    }

    // Intent (Rule 9): the managed block must export exactly the 4 vars iris doctor
    // checks, pointing at the real proxy (Config.swift:38) and ca.pem. Breaks if a
    // constant drifts.
    func testRenderBlockContainsCanonicalExports() {
        let block = ShellProfileConfigurator.renderBlock()
        XCTAssertTrue(block.contains(ShellProfileConfigurator.beginMarker))
        XCTAssertTrue(block.contains(ShellProfileConfigurator.endMarker))
        XCTAssertTrue(block.contains("export HTTPS_PROXY=http://127.0.0.1:8888"))
        XCTAssertTrue(block.contains("export HTTP_PROXY=http://127.0.0.1:8888"))
        XCTAssertTrue(block.contains("export NODE_EXTRA_CA_CERTS=\"$HOME/Library/Application Support/iris/ca.pem\""))
        XCTAssertTrue(block.contains("export SSL_CERT_FILE=\"$HOME/Library/Application Support/iris/ca.pem\""))
    }

    func testApplyBlockToEmptyContent() {
        let out = ShellProfileConfigurator.applyBlock(to: "")
        XCTAssertTrue(ShellProfileConfigurator.containsBlock(out))
        XCTAssertEqual(blockCount(in: out), 1)
    }

    func testApplyBlockPreservesExistingContent() {
        let out = ShellProfileConfigurator.applyBlock(to: "export FOO=1\nalias x=y\n")
        XCTAssertTrue(out.contains("export FOO=1"))
        XCTAssertTrue(out.contains("alias x=y"))
        XCTAssertTrue(ShellProfileConfigurator.containsBlock(out))
    }

    func testApplyBlockIsIdempotent() {
        let once = ShellProfileConfigurator.applyBlock(to: "export FOO=1\n")
        let twice = ShellProfileConfigurator.applyBlock(to: once)
        XCTAssertEqual(blockCount(in: twice), 1)
        XCTAssertTrue(twice.contains("export FOO=1"))
    }

    func testApplyBlockReplacesStaleBlock() {
        let stale = "# >>> iris >>>\nexport HTTPS_PROXY=http://127.0.0.1:1111\n# <<< iris <<<\n"
        let out = ShellProfileConfigurator.applyBlock(to: stale)
        XCTAssertEqual(blockCount(in: out), 1)
        XCTAssertFalse(out.contains("1111"))
        XCTAssertTrue(out.contains("8888"))
    }

    func testRemoveBlockRemovesExactlyTheBlock() {
        let content = "export FOO=1\n# >>> iris >>>\nexport HTTPS_PROXY=x\n# <<< iris <<<\nexport BAR=2\n"
        let out = ShellProfileConfigurator.removeBlock(from: content)
        XCTAssertFalse(ShellProfileConfigurator.containsBlock(out))
        XCTAssertTrue(out.contains("export FOO=1"))
        XCTAssertTrue(out.contains("export BAR=2"))
    }

    func testRemoveBlockNoOpWhenAbsent() {
        let content = "export FOO=1\n"
        XCTAssertFalse(ShellProfileConfigurator.containsBlock(ShellProfileConfigurator.removeBlock(from: content)))
        XCTAssertTrue(ShellProfileConfigurator.removeBlock(from: content).contains("export FOO=1"))
    }
}
```

- [ ] **Step 2 : Lancer les tests, vérifier l'échec de compilation**

Run: `swift test --filter ShellProfileConfiguratorTests`
Expected: FAIL — `cannot find 'ShellProfileConfigurator' in scope`.

- [ ] **Step 3 : Implémenter la logique pure**

```swift
// Sources/IrisKit/Shell/ShellProfileConfigurator.swift
import Foundation

/// Manages a single marked block of environment exports in the user's shell
/// profile (`~/.zshrc`). The block is delimited by `beginMarker`/`endMarker` so
/// it can be applied idempotently and removed exactly at uninstall — without
/// touching anything else in the file. Pure block logic here is the CI-testable
/// seam; I/O lives in the same enum (Task 2).
public enum ShellProfileConfigurator {
    public static let beginMarker = "# >>> iris >>>"
    public static let endMarker = "# <<< iris <<<"

    /// The exact exports IRIS manages. Values mirror the daemon defaults
    /// (`Config.swift:38` → 127.0.0.1:8888) and the CA export path
    /// (`~/Library/Application Support/iris/ca.pem`). Single source of truth;
    /// `iris doctor` (DoctorCommand.swift:109) checks exactly these four vars.
    public static func renderBlock(
        proxyURL: String = "http://127.0.0.1:8888",
        caPEMPath: String = "$HOME/Library/Application Support/iris/ca.pem"
    ) -> String {
        """
        \(beginMarker)
        export HTTPS_PROXY=\(proxyURL)
        export HTTP_PROXY=\(proxyURL)
        export NODE_EXTRA_CA_CERTS="\(caPEMPath)"
        export SSL_CERT_FILE="\(caPEMPath)"
        \(endMarker)
        """
    }

    public static func containsBlock(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains(beginMarker)
    }

    /// Returns `content` with the iris block removed (between and including the
    /// markers). No-op if absent. Line-based for robustness.
    public static func removeBlock(from content: String) -> String {
        var lines: [String] = []
        var inside = false
        for line in content.components(separatedBy: "\n") {
            if line == beginMarker { inside = true; continue }
            if line == endMarker { inside = false; continue }
            if !inside { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns `content` with a fresh iris block. Any existing block is removed
    /// first (idempotent + updates stale values). The block is appended with a
    /// blank-line separator when the file is non-empty.
    public static func applyBlock(to content: String, block: String = renderBlock()) -> String {
        let base = removeBlock(from: content)
        let trimmed = base.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return block + "\n" }
        return trimmed + "\n\n" + block + "\n"
    }
}
```

- [ ] **Step 4 : Lancer les tests, vérifier le succès**

Run: `swift test --filter ShellProfileConfiguratorTests`
Expected: PASS (7 tests).

- [ ] **Step 5 : Lint + commit**

```bash
swift format lint -r Sources/IrisKit/Shell Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
git add Sources/IrisKit/Shell/ShellProfileConfigurator.swift Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
git commit -m "feat(shell): bloc balisé idempotent pour le profil shell (logique pure)"
```

---

## Task 2 : `ShellProfileConfigurator` — couche I/O (fichier injectable)

**Files:**
- Modify: `Sources/IrisKit/Shell/ShellProfileConfigurator.swift`
- Test: `Tests/IrisKitTests/ShellProfileConfiguratorTests.swift`

- [ ] **Step 1 : Ajouter les tests I/O (échec attendu)**

```swift
// Append inside final class ShellProfileConfiguratorTests
func testInstallWritesBlockToFile() throws {
    let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try "export FOO=1\n".write(toFile: tmp, atomically: true, encoding: .utf8)

    try ShellProfileConfigurator.install(profilePath: tmp)

    let written = try String(contentsOfFile: tmp, encoding: .utf8)
    XCTAssertTrue(written.contains("export FOO=1"))
    XCTAssertTrue(ShellProfileConfigurator.containsBlock(written))
    XCTAssertTrue(ShellProfileConfigurator.isInstalled(profilePath: tmp))
}

func testInstallCreatesFileWhenAbsent() throws {
    let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try ShellProfileConfigurator.install(profilePath: tmp)

    XCTAssertTrue(ShellProfileConfigurator.isInstalled(profilePath: tmp))
}

func testUninstallRemovesBlockKeepsRest() throws {
    let tmp = NSTemporaryDirectory() + "iris-test-\(UUID().uuidString).zshrc"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try "export FOO=1\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    try ShellProfileConfigurator.install(profilePath: tmp)

    try ShellProfileConfigurator.uninstall(profilePath: tmp)

    let written = try String(contentsOfFile: tmp, encoding: .utf8)
    XCTAssertFalse(ShellProfileConfigurator.isInstalled(profilePath: tmp))
    XCTAssertTrue(written.contains("export FOO=1"))
}

func testIsInstalledFalseWhenFileAbsent() {
    let tmp = NSTemporaryDirectory() + "iris-absent-\(UUID().uuidString).zshrc"
    XCTAssertFalse(ShellProfileConfigurator.isInstalled(profilePath: tmp))
}
```

- [ ] **Step 2 : Lancer, vérifier l'échec**

Run: `swift test --filter ShellProfileConfiguratorTests`
Expected: FAIL — `install`/`uninstall`/`isInstalled` introuvables.

- [ ] **Step 3 : Implémenter la couche I/O**

```swift
// Append inside enum ShellProfileConfigurator (Sources/IrisKit/Shell/ShellProfileConfigurator.swift)

    /// Default target: the current user's `~/.zshrc` (macOS default shell).
    public static func defaultProfilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc").path
    }

    /// Adds (or refreshes) the iris block in `profilePath`, creating the file if
    /// absent. Atomic write — never a partial file.
    public static func install(profilePath: String = defaultProfilePath()) throws {
        let existing = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
        try applyBlock(to: existing).write(toFile: profilePath, atomically: true, encoding: .utf8)
    }

    /// Removes the iris block from `profilePath`. No-op if the file or block is
    /// absent.
    public static func uninstall(profilePath: String = defaultProfilePath()) throws {
        guard let existing = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return }
        try removeBlock(from: existing).write(toFile: profilePath, atomically: true, encoding: .utf8)
    }

    public static func isInstalled(profilePath: String = defaultProfilePath()) -> Bool {
        guard let existing = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return false }
        return containsBlock(existing)
    }
```

- [ ] **Step 4 : Lancer, vérifier le succès**

Run: `swift test --filter ShellProfileConfiguratorTests`
Expected: PASS (11 tests).

- [ ] **Step 5 : Lint + commit**

```bash
swift format lint -r Sources/IrisKit/Shell Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
git add Sources/IrisKit/Shell/ShellProfileConfigurator.swift Tests/IrisKitTests/ShellProfileConfiguratorTests.swift
git commit -m "feat(shell): écriture atomique install/uninstall/isInstalled du profil"
```

---

## Task 3 : Commande CLI `iris shell` (install/uninstall/status)

**Files:**
- Create: `Sources/iris/Commands/ShellCommands.swift`
- Modify: `Sources/iris/IrisCLI.swift` (ajouter `ShellCommand.self`)

> Pas de TDD unitaire ici : la commande est fine (toute la logique est dans
> `ShellProfileConfigurator`, déjà testée), et l'aspect interactif (`readLine`)
> n'est pas testable déterministiquement → vérifié en smoke (Task 8). On vérifie
> la compilation et le comportement non-interactif (`--yes`) à la main.

- [ ] **Step 1 : Créer la commande**

```swift
// Sources/iris/Commands/ShellCommands.swift
import ArgumentParser
import Foundation
import IrisKit

struct ShellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Configure the shell profile (~/.zshrc) to route CLI traffic through IRIS.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Add the IRIS environment block to ~/.zshrc (asks first)."
        )

        @Flag(name: .customLong("yes"), help: "Skip the confirmation prompt.")
        var assumeYes: Bool = false
        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            if ShellProfileConfigurator.isInstalled() {
                try Output.ack(message: "already configured", json: json)
                return
            }
            let block = ShellProfileConfigurator.renderBlock()
            if !assumeYes {
                FileHandle.standardError.write(Data(
                    "The following lines will be added to ~/.zshrc:\n\n\(block)\n\nProceed? [y/N] ".utf8
                ))
                let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    try Output.ack(message: "cancelled", json: json)
                    return
                }
            }
            do {
                try ShellProfileConfigurator.install()
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("shell install failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "shell configured — open a new terminal window", json: json)
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove the IRIS environment block from ~/.zshrc."
        )

        @Flag(name: .customLong("json")) var json: Bool = false

        mutating func run() async throws {
            if !ShellProfileConfigurator.isInstalled() {
                try Output.ack(message: "not configured", json: json)
                return
            }
            do {
                try ShellProfileConfigurator.uninstall()
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("shell uninstall failed: \(error)\n".utf8))
                throw ExitCode(IrisExitCode.ioError)
            }
            try Output.ack(message: "shell block removed", json: json)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report whether the IRIS block is present in ~/.zshrc."
        )

        @Flag(name: .customLong("json")) var json: Bool = false

        struct Result: Encodable { let configured: Bool }

        mutating func run() async throws {
            let configured = ShellProfileConfigurator.isInstalled()
            try Output.print(
                humanText: configured ? "configured" : "not configured",
                jsonValue: Result(configured: configured),
                json: json
            )
        }
    }
}
```

- [ ] **Step 2 : Enregistrer la sous-commande**

Dans `Sources/iris/IrisCLI.swift`, ajouter `ShellCommand.self` à la liste `subcommands` (après `CACommand.self`) :

```swift
            CACommand.self,
            ShellCommand.self,
            ConfigCommand.self,
```

- [ ] **Step 3 : Build**

Run: `swift build`
Expected: succès, aucune erreur.

- [ ] **Step 4 : Vérifier le comportement non-interactif à la main**

Run:
```bash
T=$(mktemp); HOME=$(mktemp -d)
.build/debug/iris shell status            # → "not configured"
.build/debug/iris shell install --yes     # → "shell configured ..."
.build/debug/iris shell status            # → "configured"
cat "$HOME/.zshrc"                         # bloc présent
.build/debug/iris shell uninstall         # → "shell block removed"
.build/debug/iris shell status            # → "not configured"
```
Expected: la séquence ci-dessus (le bloc apparaît puis disparaît dans `$HOME/.zshrc`).

- [ ] **Step 5 : Lint + commit**

```bash
swift format lint -r Sources/iris/Commands/ShellCommands.swift Sources/iris/IrisCLI.swift
git add Sources/iris/Commands/ShellCommands.swift Sources/iris/IrisCLI.swift
git commit -m "feat(cli): commande iris shell install/uninstall/status"
```

---

## Task 4 : Seam `ShellConfiguring` (IrisAppCore)

**Files:**
- Create: `Sources/IrisAppCore/ShellConfiguring.swift`

> Réplique exacte du pattern `CATrustInstalling` (`Sources/IrisAppCore/CATrustInstalling.swift`).
> L'impl système n'est pas unit-testée (I/O réelle) ; elle est couverte par les tests
> d'AppModel via un fake (Task 5) et le smoke (Task 8).

- [ ] **Step 1 : Créer le seam**

```swift
// Sources/IrisAppCore/ShellConfiguring.swift
import IrisKit

/// Seam over the shell-profile mutation so AppModel's configure/unconfigure
/// orchestration is unit-testable with a fake. Mirrors `CATrustInstalling`.
public protocol ShellConfiguring: Sendable {
    func install() throws
    func uninstall() throws
    func isInstalled() -> Bool
}

/// Production impl: delegates to IrisKit's `ShellProfileConfigurator` (writes
/// `~/.zshrc`). Covered by manual smoke, not unit tests.
public struct SystemShellConfigurator: ShellConfiguring {
    public init() {}
    public func install() throws { try ShellProfileConfigurator.install() }
    public func uninstall() throws { try ShellProfileConfigurator.uninstall() }
    public func isInstalled() -> Bool { ShellProfileConfigurator.isInstalled() }
}
```

- [ ] **Step 2 : Build**

Run: `swift build`
Expected: succès.

- [ ] **Step 3 : Commit**

```bash
swift format lint -r Sources/IrisAppCore/ShellConfiguring.swift
git add Sources/IrisAppCore/ShellConfiguring.swift
git commit -m "feat(app-core): seam ShellConfiguring (réplique CATrustInstalling)"
```

---

## Task 5 : `AppModel.configureShell/unconfigureShell` + état

**Files:**
- Modify: `Sources/IrisAppCore/AppModel.swift`
- Create: `Tests/IrisAppCoreTests/Mocks/FakeShellConfigurator.swift`
- Create: `Tests/IrisAppCoreTests/AppModelShellTests.swift`

- [ ] **Step 1 : Créer le fake (modèle `FakeCATrustInstaller`)**

```swift
// Tests/IrisAppCoreTests/Mocks/FakeShellConfigurator.swift
import Foundation

@testable import IrisAppCore

final class FakeShellConfigurator: ShellConfiguring, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = false
    var shouldThrow: Error?

    var installed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _installed
    }

    func install() throws {
        if let e = shouldThrow { throw e }
        lock.lock(); _installed = true; lock.unlock()
    }

    func uninstall() throws {
        if let e = shouldThrow { throw e }
        lock.lock(); _installed = false; lock.unlock()
    }

    func isInstalled() -> Bool { installed }
}
```

- [ ] **Step 2 : Écrire les tests AppModel (échec attendu)**

```swift
// Tests/IrisAppCoreTests/AppModelShellTests.swift
import XCTest

@testable import IrisAppCore

@MainActor
final class AppModelShellTests: XCTestCase {
    private func makeModel(_ fake: FakeShellConfigurator) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "io.iris.app.tests.\(UUID().uuidString)")!,
            shellConfigurator: fake
        )
    }

    func testConfigureShellInstallsAndReflectsState() async throws {
        let fake = FakeShellConfigurator()
        let model = makeModel(fake)
        try await model.configureShell()
        XCTAssertTrue(fake.installed)
        XCTAssertEqual(model.shellConfigured, true)
    }

    func testUnconfigureShellRemovesAndReflectsState() async throws {
        let fake = FakeShellConfigurator()
        try fake.install()
        let model = makeModel(fake)
        try await model.unconfigureShell()
        XCTAssertFalse(fake.installed)
        XCTAssertEqual(model.shellConfigured, false)
    }

    func testRefreshShellConfiguredReadsSeam() {
        let fake = FakeShellConfigurator()
        try? fake.install()
        let model = makeModel(fake)
        model.refreshShellConfigured()
        XCTAssertEqual(model.shellConfigured, true)
    }
}
```

- [ ] **Step 3 : Lancer, vérifier l'échec**

Run: `swift test --filter AppModelShellTests`
Expected: FAIL — `shellConfigurator:` param et `configureShell`/`unconfigureShell`/`shellConfigured`/`refreshShellConfigured` introuvables.

- [ ] **Step 4 : Implémenter dans AppModel**

Dans `Sources/IrisAppCore/AppModel.swift` :

(a) Ajouter le champ stocké (près de `caInstaller`, ligne 34) :
```swift
    private let shellConfigurator: ShellConfiguring
```

(b) Ajouter une propriété publiée (près des autres `@Published`) :
```swift
    @Published public private(set) var shellConfigured: Bool?
```

(c) Ajouter le paramètre d'init (dans `init`, après `caInstaller:`) et l'assignation :
```swift
    public init(
        defaults: UserDefaults = .standard,
        caInstaller: CATrustInstalling = SystemCATrustInstaller(),
        shellConfigurator: ShellConfiguring = SystemShellConfigurator(),
        autoStart: AutoStartControlling = SystemAutoStartService()
    ) {
        self.defaults = defaults
        self.caInstaller = caInstaller
        self.shellConfigurator = shellConfigurator
        self.autoStart = autoStart
        // … reste inchangé …
```

(d) Ajouter les méthodes (à côté de `installCA`/`uninstallCA`, ligne 233) :
```swift
    public func refreshShellConfigured() {
        shellConfigured = shellConfigurator.isInstalled()
    }

    public func configureShell() async throws {
        let cfg = shellConfigurator
        try await Task.detached { try cfg.install() }.value
        refreshShellConfigured()
    }

    public func unconfigureShell() async throws {
        let cfg = shellConfigurator
        try await Task.detached { try cfg.uninstall() }.value
        refreshShellConfigured()
    }
```

- [ ] **Step 5 : Lancer, vérifier le succès**

Run: `swift test --filter AppModelShellTests`
Expected: PASS (3 tests).

- [ ] **Step 6 : Lint + commit**

```bash
swift format lint -r Sources/IrisAppCore/AppModel.swift Tests/IrisAppCoreTests/Mocks/FakeShellConfigurator.swift Tests/IrisAppCoreTests/AppModelShellTests.swift
git add Sources/IrisAppCore/AppModel.swift Tests/IrisAppCoreTests/Mocks/FakeShellConfigurator.swift Tests/IrisAppCoreTests/AppModelShellTests.swift
git commit -m "feat(app-core): AppModel configureShell/unconfigureShell + état shellConfigured"
```

---

## Task 6 : Bouton « Terminal » dans l'onglet Settings

**Files:**
- Modify: `IrisApp/IrisApp/SettingsTab.swift`

> SwiftUI : pas de test unitaire automatique (la cible IrisApp n'est pas en
> strict-concurrency et n'est pas testée unitairement, cf. leçon 6.3b). Vérification
> = build CI + smoke (Task 8). Suit le pattern `caBox()` / `caAction()`.

- [ ] **Step 1 : Ajouter la vue `shellBox()`** (modèle exact de `caBox()`, lignes 91-112)

```swift
    @ViewBuilder private func shellBox() -> some View {
        GroupBox("Terminal") {
            HStack {
                switch model.shellConfigured {
                case .some(true):
                    Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false):
                    Label("Not configured", systemImage: "circle").foregroundStyle(.orange)
                case nil:
                    Text("Unknown").foregroundStyle(.secondary)
                }
                Spacer()
                if model.shellConfigured == true {
                    Button("Remove…") { shellAction(install: false) }
                } else {
                    Button("Configure…") { shellAction(install: true) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
```

- [ ] **Step 2 : Ajouter l'action `shellAction(install:)`** (modèle de `caAction(install:)`, lignes 211-219)

```swift
    private func shellAction(install: Bool) {
        Task {
            errorText = nil
            do {
                if install { try await model.configureShell() } else { try await model.unconfigureShell() }
            } catch {
                errorText = userMessage(error)
            }
        }
    }
```

- [ ] **Step 3 : Insérer `shellBox()` dans le corps de l'onglet et rafraîchir l'état**

(a) Dans `body` (`SettingsTab.swift:21`), ajouter `shellBox()` juste **après** `caBox()` :
```swift
                    caBox()
                    shellBox()
                    autoStartBox()
```

(b) Le `body` appelle `.task { await reload() }` (ligne 37). Dans la fonction `reload()`, ajouter
`model.refreshShellConfigured()` à côté de l'appel qui rafraîchit l'état CA
(`model.refreshCATrust(via: admin)`). C'est synchrone — pas de `await`.

> Note : `refreshShellConfigured()` lit `~/.zshrc` sur le main actor (lecture courte,
> comme `refreshAutoStart()`).

- [ ] **Step 4 : Build local**

Run: `swift build`
Expected: succès. (Le rendu réel est validé en smoke + CI Xcode.)

- [ ] **Step 5 : Commit**

```bash
git add IrisApp/IrisApp/SettingsTab.swift
git commit -m "feat(app): bouton Terminal dans Settings (configurer/retirer le shell)"
```

---

## Task 7 : Packaging — livrer `iris` dans `/usr/local/bin`

**Files:**
- Modify: `packaging/build-pkg.sh`
- Modify: `packaging/installer/Distribution.xml`

> Pas de test unitaire (script de build) → smoke (Task 8). Suivre le pattern de
> signature inner-first existant ; le CLI est un binaire non-bundle (`-i io.iris.cli`),
> hardened runtime, **sans** entitlements ni ACL Keychain (le CLI est pur RPC).

- [ ] **Step 1 : Builder et stager le CLI `iris`** dans `build-pkg.sh`

Après la section « 1. Build irisd » (qui fait `swift build -c release --product irisd`), builder aussi le CLI et le stager dans une racine dédiée :

```bash
# --- 1b. Build + stage CLI iris (→ /usr/local/bin) ------------------------
swift build -c release --product iris
IRIS_CLI_BIN=".build/release/iris"
[ -f "$IRIS_CLI_BIN" ] || { echo "error: $IRIS_CLI_BIN introuvable après build" >&2; exit 1; }
CLI_ROOT="$BUILD/cli-root/usr/local/bin"
mkdir -p "$CLI_ROOT"
ditto "$IRIS_CLI_BIN" "$CLI_ROOT/iris"
# Signature Developer ID (hardened runtime, identifiant non-bundle, sans entitlements).
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime -i io.iris.cli "$CLI_ROOT/iris"
```

- [ ] **Step 2 : Construire le composant pkg du CLI** (après la construction du composant app, section 7b)

```bash
#   d. Composant CLI : installe iris dans /usr/local/bin.
CLI_COMPONENT_PKG="$COMPONENT_DIR/Iris-cli.pkg"
pkgbuild --root "$BUILD/cli-root/usr/local/bin" --install-location /usr/local/bin \
  --identifier io.iris.cli --version "$VERSION" \
  "$CLI_COMPONENT_PKG"
```

- [ ] **Step 3 : Référencer le composant CLI dans `Distribution.xml`**

Ajouter le `pkg-ref`, le `choice` et la `line` (à côté de `io.iris.app`) :

```xml
    <choices-outline>
        <line choice="default">
            <line choice="io.iris.app"/>
            <line choice="io.iris.cli"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="io.iris.app" visible="false">
        <pkg-ref id="io.iris.app"/>
    </choice>
    <choice id="io.iris.cli" visible="false">
        <pkg-ref id="io.iris.cli"/>
    </choice>
    <pkg-ref id="io.iris.app" version="0.1.0" onConclusion="none">Iris-component.pkg</pkg-ref>
    <pkg-ref id="io.iris.cli" version="0.1.0" onConclusion="none">Iris-cli.pkg</pkg-ref>
```

> `productbuild --package-path "$COMPONENT_DIR"` (déjà en place) trouvera `Iris-cli.pkg`
> dans le même dossier. La substitution `version` du `sed` existant couvre les deux
> `pkg-ref` (remplacement global).

- [ ] **Step 4 : Vérifier la syntaxe du script** (sans certs Developer ID, build complet = smoke poste)

Run: `bash -n packaging/build-pkg.sh`
Expected: aucune erreur de syntaxe.

- [ ] **Step 5 : Commit**

```bash
git add packaging/build-pkg.sh packaging/installer/Distribution.xml
git commit -m "feat(packaging): livrer le CLI iris dans /usr/local/bin (composant pkg signé)"
```

---

## Task 8 : Corriger la documentation et les écrans d'installeur

**Files:**
- Modify: `docs/user-guide.md` (§3 et §4.1)
- Modify: `packaging/installer/resources/en.lproj/conclusion.html`
- Modify: `packaging/installer/resources/fr.lproj/conclusion.html`
- Modify: `packaging/installer/resources/en.lproj/readme.html`
- Modify: `packaging/installer/resources/fr.lproj/readme.html`

- [ ] **Step 1 : `user-guide.md §3`** — corriger la liste d'installation

Remplacer les lignes fausses (irisd `/usr/local/libexec/`, LaunchAgent `~/Library/LaunchAgents/`,
`launchctl bootstrap`) par la réalité :
- `Iris.app` dans `/Applications/`.
- La CLI `iris` dans `/usr/local/bin/`.
- Le daemon `irisd` est **embarqué dans `Iris.app`** et géré par **SMAppService** (pas de
  fichier dans `/usr/local/libexec/`, pas de `launchctl bootstrap`).
- Le démarrage automatique se règle dans **Réglages → Ouverture au démarrage** ou via les
  toggles de l'onglet Settings de l'app (Phase 7).

- [ ] **Step 2 : `user-guide.md §4.1`** — corriger le « patch automatique de ~/.zshrc »

Remplacer « Patch automatique de `~/.zshrc` … » par : la config terminal se fait **avec
consentement** — soit `iris shell install` (affiche le bloc, demande confirmation), soit le bouton
« Configurer le terminal » dans l'onglet Settings. Mentionner les 4 variables exportées.

- [ ] **Step 3 : `conclusion.html` (en + fr)** — corriger l'étape 3

Remplacer « Il configure votre shell automatiquement. Sinon, lancez `iris ca install` … » par une
formulation exacte : « Pour router votre terminal via Iris, lancez `iris shell install` (il vous
montre les lignes et demande confirmation), ou utilisez le bouton « Configurer le terminal » dans
les réglages de l'app. » (et idem en anglais).

- [ ] **Step 4 : `readme.html` (en + fr)** — corriger « configure pour vous … au premier lancement »

Remplacer l'affirmation d'automatisme par : « Iris peut configurer votre terminal **avec votre
accord** (via `iris shell install` ou les réglages de l'app). » Conserver la liste des variables.

- [ ] **Step 5 : Vérifier qu'aucune mention obsolète ne subsiste**

Run:
```bash
grep -rn -e "usr/local/libexec" -e "launchctl bootstrap" docs/user-guide.md packaging/installer/resources/
```
Expected: aucun résultat.

- [ ] **Step 6 : Commit**

```bash
git add docs/user-guide.md packaging/installer/resources/
git commit -m "docs: aligner installation (CLI iris, config terminal consentie, SMAppService) sur la réalité"
```

---

## Vérification finale (avant PR)

- [ ] `swift build` — succès.
- [ ] `swift test` — toute la suite verte (les ~14 nouveaux tests inclus).
- [ ] `swift format lint -r Sources Tests` — propre.
- [ ] Smoke poste (checklist du spec §8) : `.pkg` installe `iris` dans `/usr/local/bin` ; `iris
      shell install` interactif ; bouton Settings ; survie au drag-to-trash ; doc relue.

## Critères de réussite (rappel spec §8)

- [ ] `which iris` → `/usr/local/bin/iris` après `.pkg`.
- [ ] `iris shell install` montre le bloc, demande O/N ; « non » → `~/.zshrc` intact.
- [ ] Accord (ou bouton Settings) → `iris doctor` voit les variables ; `claude` intercepté.
- [ ] `iris shell install` 2× → pas de doublon ; `iris shell uninstall` → bloc retiré, reste intact.
- [ ] `iris` répond encore après drag-to-trash de l'app.
- [ ] Plus aucune mention `/usr/local/libexec` / `launchctl bootstrap` dans doc + installeur.
