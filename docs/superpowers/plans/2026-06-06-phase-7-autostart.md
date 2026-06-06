# Phase 7 — Auto-start (SMAppService) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** L'app menu-bar enregistre `irisd` (LaunchAgent) et elle-même (login-item) via `SMAppService`, automatiquement au premier lancement et manuellement via deux toggles dans Settings.

**Architecture:** Un seam `Sendable` unifié (`AutoStartControlling`) injecté dans `AppModel`, réplique exacte du pattern `CATrustInstalling` : impl prod réelle (`SystemAutoStartService`, `import ServiceManagement`) smoke-only, fake en mémoire pour les tests headless. La logique d'orchestration (refresh, register/unregister idempotents, indépendance des cibles) vit dans `AppModel` (testée par `swift test`). L'UI (`SettingsTab`), le déclenchement (`AppDelegate --first-launch`) et le packaging (plist + postinstall) sont vérifiés au build app + smoke poste.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, `ServiceManagement.SMAppService` (macOS 13+), XCTest, SwiftPM (`IrisAppCore`) + Xcode (`IrisApp`).

**Réf design :** `docs/superpowers/specs/2026-06-06-phase-7-autostart-design.md`

---

## File Structure

**Créer**
- `Sources/IrisAppCore/AutoStart/AutoStartService.swift` — enums `AutoStartTarget`/`AutoStartStatus` + protocole `AutoStartControlling`. Pas de logique, pas de dépendance système. Une responsabilité : le contrat.
- `Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift` — impl prod, `import ServiceManagement`, mappe le contrat ↔ `SMAppService`. Smoke-only (jamais exécutée en test : `Bundle.main` = test-runner).
- `Tests/IrisAppCoreTests/Mocks/FakeAutoStartService.swift` — fake en mémoire, enregistre les appels, statut scriptable.
- `Tests/IrisAppCoreTests/AutoStartTests.swift` — tests d'orchestration `AppModel`.

**Modifier**
- `Sources/IrisAppCore/AppModel.swift` — état publié + seam injecté + `refreshAutoStart`/`setAutoStart`/`openLoginItemsSettings`.
- `IrisApp/IrisApp/SettingsTab.swift` — `GroupBox "Launch at login"`.
- `IrisApp/IrisApp/AppDelegate.swift` — détection `--first-launch`.
- `packaging/io.iris.daemon.plist` — `ThrottleInterval=30`.
- `packaging/scripts/postinstall` — relance `--first-launch`.

---

## Task 1: Contrat du seam (enums + protocole)

**Files:**
- Create: `Sources/IrisAppCore/AutoStart/AutoStartService.swift`

- [ ] **Step 1: Écrire le fichier de contrat**

```swift
import Foundation

/// Les deux services auto-démarrables. `daemon` = LaunchAgent `irisd` ;
/// `app` = la menu-bar app comme login-item.
public enum AutoStartTarget: Sendable, CaseIterable, Hashable {
    case daemon
    case app
}

/// État maison (pas `SMAppService.Status`) : garde IrisAppCore testable sans
/// dépendre du contexte bundle, exactement comme `AppModel.caTrusted: Bool?`.
public enum AutoStartStatus: Sendable, Equatable {
    /// Enregistré et éligible à tourner.
    case enabled
    /// Enregistré mais l'utilisateur doit autoriser en Réglages Système.
    case requiresApproval
    /// Non enregistré (off).
    case notRegistered
    /// Plist/bundle introuvable (anomalie de packaging).
    case notFound
    /// État illisible (cas `@unknown` futur).
    case unknown
}

/// Seam sur `SMAppService` (API in-process, non testable hors bundle installé).
/// Production : `SystemAutoStartService`. Tests : `FakeAutoStartService`.
public protocol AutoStartControlling: Sendable {
    func status(_ target: AutoStartTarget) -> AutoStartStatus
    func register(_ target: AutoStartTarget) throws
    func unregister(_ target: AutoStartTarget) throws
    func openLoginItemsSettings()
}
```

- [ ] **Step 2: Compiler**

Run: `swift build`
Expected: build succeeds (nouveau fichier, aucune utilisation encore).

- [ ] **Step 3: Commit**

```bash
git add Sources/IrisAppCore/AutoStart/AutoStartService.swift
git commit -m "feat(phase-7): AutoStart seam contract (enums + protocol)"
```

---

## Task 2: Fake testable

**Files:**
- Create: `Tests/IrisAppCoreTests/Mocks/FakeAutoStartService.swift`

- [ ] **Step 1: Écrire le fake** (calqué sur `FakeCATrustInstaller`)

```swift
import Foundation

@testable import IrisAppCore

/// In-memory `AutoStartControlling` : statut scriptable par cible, journal des
/// appels register/unregister, et `shouldThrow` pour simuler un échec.
/// `@unchecked Sendable` : l'état est protégé par NSLock — register/unregister
/// sont appelés depuis le `Task.detached` d'AppModel, les lectures depuis le test.
final class FakeAutoStartService: AutoStartControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _statuses: [AutoStartTarget: AutoStartStatus] = [:]
    var shouldThrow: Error?

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func setStatus(_ status: AutoStartStatus, for target: AutoStartTarget) {
        lock.lock()
        _statuses[target] = status
        lock.unlock()
    }

    func status(_ target: AutoStartTarget) -> AutoStartStatus {
        lock.lock()
        defer { lock.unlock() }
        return _statuses[target] ?? .notRegistered
    }

    func register(_ target: AutoStartTarget) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _calls.append("register(\(target))")
        _statuses[target] = .enabled
        lock.unlock()
    }

    func unregister(_ target: AutoStartTarget) throws {
        if let e = shouldThrow { throw e }
        lock.lock()
        _calls.append("unregister(\(target))")
        _statuses[target] = .notRegistered
        lock.unlock()
    }

    func openLoginItemsSettings() {
        lock.lock()
        _calls.append("openLoginItemsSettings")
        lock.unlock()
    }
}
```

- [ ] **Step 2: Compiler les tests** (le fake doit compiler avec le contrat de Task 1)

Run: `swift build --build-tests`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Tests/IrisAppCoreTests/Mocks/FakeAutoStartService.swift
git commit -m "test(phase-7): FakeAutoStartService"
```

---

## Task 3: `refreshAutoStart` (TDD)

**Files:**
- Create: `Tests/IrisAppCoreTests/AutoStartTests.swift`
- Modify: `Sources/IrisAppCore/AppModel.swift`

- [ ] **Step 1: Écrire le test échouant**

Créer `Tests/IrisAppCoreTests/AutoStartTests.swift` :

```swift
import IrisKit
import XCTest

@testable import IrisAppCore

@MainActor
final class AutoStartTests: XCTestCase {
    private func makeModel(_ fake: FakeAutoStartService) -> AppModel {
        AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, autoStart: fake)
    }

    func testRefreshAutoStartCopiesSeamStatus() {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .daemon)
        fake.setStatus(.requiresApproval, for: .app)
        let model = makeModel(fake)

        model.refreshAutoStart()

        XCTAssertEqual(model.daemonAutoStart, .enabled)
        XCTAssertEqual(model.appAutoStart, .requiresApproval)
    }
}
```

- [ ] **Step 2: Vérifier l'échec de compilation/test**

Run: `swift test --filter AutoStartTests`
Expected: FAIL — `AppModel` n'a ni `init(autoStart:)`, ni `daemonAutoStart`, ni `appAutoStart`, ni `refreshAutoStart`.

- [ ] **Step 3: Implémenter dans `AppModel.swift`**

(a) Après la ligne `@Published public var caTrusted: Bool?` (≈ l.17), ajouter :
```swift
    @Published public var daemonAutoStart: AutoStartStatus?
    @Published public var appAutoStart: AutoStartStatus?
```

(b) Après `private let caInstaller: CATrustInstalling` (≈ l.32), ajouter :
```swift
    private let autoStart: AutoStartControlling
```

(c) Modifier la signature et le corps de `init` :
```swift
    public init(
        defaults: UserDefaults = .standard,
        caInstaller: CATrustInstalling = SystemCATrustInstaller(),
        autoStart: AutoStartControlling = SystemAutoStartService()
    ) {
        self.defaults = defaults
        self.caInstaller = caInstaller
        self.autoStart = autoStart
```
(garder le reste du corps `init` inchangé : `selectedTab`, `lastAcknowledgedAt`).

(d) Avant l'accolade fermante finale de la classe (juste après `uninstallCA`, ≈ l.228), ajouter :
```swift

    public func refreshAutoStart() {
        daemonAutoStart = autoStart.status(.daemon)
        appAutoStart = autoStart.status(.app)
    }
```

> Note : `SystemAutoStartService()` (défaut du nouveau param) est créé en Task 5. D'ici là, `swift build` échoue sur ce nom. Pour garder Task 3 vert **maintenant**, créer le squelette minimal de `SystemAutoStartService` AVANT de lancer les tests (Step 4), ou exécuter Task 5 Step 1 dès maintenant. Le plan suppose que tu crées d'abord le squelette ci-dessous puis reviens — c'est le seul ordre où `swift test` passe :

`Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift` (squelette, complété en Task 5) :
```swift
import Foundation
import ServiceManagement

public struct SystemAutoStartService: AutoStartControlling {
    public init() {}
    public func status(_ target: AutoStartTarget) -> AutoStartStatus { .unknown }
    public func register(_ target: AutoStartTarget) throws {}
    public func unregister(_ target: AutoStartTarget) throws {}
    public func openLoginItemsSettings() {}
}
```

- [ ] **Step 4: Vérifier le test au vert**

Run: `swift test --filter AutoStartTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisAppCore/AppModel.swift Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift Tests/IrisAppCoreTests/AutoStartTests.swift
git commit -m "feat(phase-7): AppModel.refreshAutoStart + autoStart seam injection"
```

---

## Task 4: `setAutoStart` register/unregister (TDD)

**Files:**
- Modify: `Tests/IrisAppCoreTests/AutoStartTests.swift`
- Modify: `Sources/IrisAppCore/AppModel.swift`

- [ ] **Step 1: Ajouter les tests échouants** (dans `AutoStartTests`)

```swift
    func testEnableDaemonRegistersTargetOnly() async throws {
        let fake = FakeAutoStartService()  // tout .notRegistered par défaut
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: true)

        XCTAssertEqual(fake.calls, ["register(daemon)"])  // app jamais touché
        XCTAssertEqual(model.daemonAutoStart, .enabled)
        XCTAssertEqual(model.appAutoStart, .notRegistered)
    }

    func testDisableAppUnregistersTargetOnly() async throws {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .app)
        fake.setStatus(.enabled, for: .daemon)
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.app, enabled: false)

        XCTAssertEqual(fake.calls, ["unregister(app)"])  // daemon jamais touché
        XCTAssertEqual(model.appAutoStart, .notRegistered)
        XCTAssertEqual(model.daemonAutoStart, .enabled)
    }
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter AutoStartTests`
Expected: FAIL — `setAutoStart` n'existe pas.

- [ ] **Step 3: Implémenter `setAutoStart`** dans `AppModel.swift` (juste après `refreshAutoStart`)

```swift

    public func setAutoStart(_ target: AutoStartTarget, enabled: Bool) async throws {
        let current = (target == .daemon) ? daemonAutoStart : appAutoStart
        // Idempotent : ne pas re-register/unregister un service déjà dans l'état voulu
        // (calque de `if caTrusted == true { return }`).
        if enabled, current == .enabled { return }
        if !enabled, current == .notRegistered { return }
        let service = autoStart
        try await Task.detached {
            if enabled {
                try service.register(target)
            } else {
                try service.unregister(target)
            }
        }.value
        refreshAutoStart()
    }
```

- [ ] **Step 4: Vérifier au vert**

Run: `swift test --filter AutoStartTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisAppCore/AppModel.swift Tests/IrisAppCoreTests/AutoStartTests.swift
git commit -m "feat(phase-7): AppModel.setAutoStart (register/unregister, target-scoped)"
```

---

## Task 5: Idempotence + propagation d'erreur (TDD) + impl prod réelle

**Files:**
- Modify: `Tests/IrisAppCoreTests/AutoStartTests.swift`
- Modify: `Sources/IrisAppCore/AppModel.swift` (`openLoginItemsSettings`)
- Modify: `Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift` (compléter le mapping réel)

- [ ] **Step 1: Ajouter les tests échouants**

```swift
    func testEnableIsIdempotentWhenAlreadyEnabled() async throws {
        let fake = FakeAutoStartService()
        fake.setStatus(.enabled, for: .daemon)
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: true)

        XCTAssertEqual(fake.calls, [])  // skip : aucun register
    }

    func testDisableIsIdempotentWhenAlreadyOff() async throws {
        let fake = FakeAutoStartService()  // .notRegistered
        let model = makeModel(fake)
        model.refreshAutoStart()

        try await model.setAutoStart(.daemon, enabled: false)

        XCTAssertEqual(fake.calls, [])  // skip : aucun unregister
    }

    func testRegisterErrorPropagatesAndLeavesStateUnchanged() async throws {
        struct Boom: Error {}
        let fake = FakeAutoStartService()
        fake.shouldThrow = Boom()
        let model = makeModel(fake)
        model.refreshAutoStart()  // daemonAutoStart = .notRegistered

        do {
            try await model.setAutoStart(.daemon, enabled: true)
            XCTFail("expected setAutoStart to throw")
        } catch {
            // attendu
        }

        XCTAssertEqual(fake.calls, [])           // le fake throw avant d'enregistrer
        XCTAssertEqual(model.daemonAutoStart, .notRegistered)  // pas de refresh après throw
    }

    func testOpenLoginItemsSettingsForwardsToSeam() {
        let fake = FakeAutoStartService()
        let model = makeModel(fake)

        model.openLoginItemsSettings()

        XCTAssertEqual(fake.calls, ["openLoginItemsSettings"])
    }
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter AutoStartTests`
Expected: FAIL — `openLoginItemsSettings` n'existe pas sur `AppModel` (les 3 tests d'idempotence/erreur passeraient déjà grâce au code de Task 4, mais la compilation échoue tant que `openLoginItemsSettings` manque).

- [ ] **Step 3a: Ajouter `openLoginItemsSettings`** dans `AppModel.swift` (après `setAutoStart`)

```swift

    public func openLoginItemsSettings() {
        autoStart.openLoginItemsSettings()
    }
```

- [ ] **Step 3b: Compléter `SystemAutoStartService.swift`** (remplacer le squelette par le mapping réel)

```swift
import Foundation
import ServiceManagement

/// Production `AutoStartControlling` : pont vers `SMAppService` (macOS 13+).
/// Non testée unitairement — `SMAppService` lit le bundle courant et l'état
/// `launchd`, indisponibles hors app installée. Couverte par le smoke poste.
public struct SystemAutoStartService: AutoStartControlling {
    /// Doit correspondre au plist embarqué dans `Contents/Library/LaunchAgents/`
    /// par `packaging/build-pkg.sh`.
    private static let daemonPlistName = "io.iris.daemon.plist"

    public init() {}

    private func service(for target: AutoStartTarget) -> SMAppService {
        switch target {
        case .daemon: return SMAppService.agent(plistName: Self.daemonPlistName)
        case .app: return SMAppService.mainApp
        }
    }

    public func status(_ target: AutoStartTarget) -> AutoStartStatus {
        switch service(for: target).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public func register(_ target: AutoStartTarget) throws {
        try service(for: target).register()
    }

    public func unregister(_ target: AutoStartTarget) throws {
        try service(for: target).unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
```

- [ ] **Step 4: Vérifier au vert + suite complète IrisAppCore**

Run: `swift test --filter AutoStartTests`
Expected: PASS (7 tests).

Run: `swift test`
Expected: PASS — toute la suite (les 455 tests existants + 7 nouveaux), 0 échec.

- [ ] **Step 5: Lint + commit**

Run: `swift-format lint --strict --recursive Sources Tests`
Expected: aucune sortie (clean).

```bash
git add Sources/IrisAppCore/AppModel.swift Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift Tests/IrisAppCoreTests/AutoStartTests.swift
git commit -m "feat(phase-7): idempotence, error propagation, openLoginItemsSettings + SMAppService mapping"
```

---

## Task 6: UI — `GroupBox "Launch at login"` dans Settings

**Files:**
- Modify: `IrisApp/IrisApp/SettingsTab.swift`

> Pas de test unitaire (cible Xcode `IrisApp`, hors strict-concurrency, non testée — cf. mémoire 6.3b). Vérification = build app + smoke.

- [ ] **Step 1: Insérer l'appel de section** dans `body`

Dans le `VStack` du `body`, après `caBox()` (≈ l.21), ajouter la ligne :
```swift
                    autoStartBox()
```
(ordre final : `securityBox(cfg)`, `backupsBox()`, `caBox()`, `autoStartBox()`, `connectionBox(cfg)`, `footer()`).

- [ ] **Step 2: Ajouter les vues de section** (après `caBox()`, dans la zone `// MARK: - Sections`)

```swift
    @ViewBuilder private func autoStartBox() -> some View {
        GroupBox("Launch at login") {
            VStack(alignment: .leading, spacing: 8) {
                autoStartRow("Background service (irisd)", status: model.daemonAutoStart, target: .daemon)
                Divider()
                autoStartRow("Menu bar app (Iris)", status: model.appAutoStart, target: .app)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private func autoStartRow(
        _ label: String,
        status: AutoStartStatus?,
        target: AutoStartTarget
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            switch status {
            case .requiresApproval?:
                Label("Needs approval", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Login Items…") { model.openLoginItemsSettings() }
            case .notFound?, .unknown?:
                Text("Unavailable").foregroundStyle(.secondary)
            default:  // .enabled / .notRegistered / nil (en cours de chargement)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { status == .enabled },
                        set: { newValue in toggleAutoStart(target, enabled: newValue) }
                    )
                )
                .labelsHidden()
            }
        }
    }
```

- [ ] **Step 3: Ajouter l'action** (dans `// MARK: - Actions`, après `caAction`)

```swift
    private func toggleAutoStart(_ target: AutoStartTarget, enabled: Bool) {
        Task {
            errorText = nil
            do {
                try await model.setAutoStart(target, enabled: enabled)
            } catch {
                errorText = userMessage(error)
            }
        }
    }
```

- [ ] **Step 4: Rafraîchir l'état au chargement** — dans `reload()`, après `try await model.refreshCATrust(via: admin)` (≈ l.197), ajouter :
```swift
            model.refreshAutoStart()
```

- [ ] **Step 5: Build app (garde-fou local)**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (NB : le verdict ferme reste le CI macOS-15 ; SourceKit peut afficher de faux « Cannot find type » — l'oracle est ce build CLI.)

- [ ] **Step 6: Commit**

```bash
git add IrisApp/IrisApp/SettingsTab.swift
git commit -m "feat(phase-7): Settings 'Launch at login' (two toggles + approval shortcut)"
```

---

## Task 7: Déclenchement `--first-launch` dans `AppDelegate`

**Files:**
- Modify: `IrisApp/IrisApp/AppDelegate.swift`

- [ ] **Step 1: Ajouter l'import** en tête de `AppDelegate.swift` (après `import Combine`)

```swift
import os
```

- [ ] **Step 2: Enregistrer au premier lancement** — dans `applicationDidFinishLaunching`, juste après la garde multi-instance (le `if NSRunningApplication... { NSApp.terminate(nil); return }` se terminant ≈ l.31), ajouter :

```swift
        // Phase 7 : le postinstall relance l'app avec `--first-launch` pour enregistrer
        // les services SMAppService dès l'installation (idempotent, best-effort). Hors
        // main-actor : register() peut bloquer sur l'IPC launchd. Un échec n'est pas
        // bloquant — l'utilisateur garde les toggles de Settings.
        if CommandLine.arguments.contains("--first-launch") {
            Task.detached {
                let service = SystemAutoStartService()
                let log = Logger(subsystem: "io.iris.app", category: "autostart")
                for target in AutoStartTarget.allCases {
                    do {
                        try service.register(target)
                    } catch {
                        log.error("first-launch register(\(String(describing: target))) failed: \(error.localizedDescription)")
                    }
                }
            }
        }
```

- [ ] **Step 3: Build app**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add IrisApp/IrisApp/AppDelegate.swift
git commit -m "feat(phase-7): register SMAppService services on --first-launch"
```

---

## Task 8: Plist daemon — `ThrottleInterval`

**Files:**
- Modify: `packaging/io.iris.daemon.plist`

- [ ] **Step 1: Ajouter la clé** — dans le `<dict>`, après le bloc `KeepAlive` (`<key>KeepAlive</key><true/>`), insérer :
```xml
    <key>ThrottleInterval</key>
    <integer>30</integer>
```

- [ ] **Step 2: Valider le plist**

Run: `plutil -lint packaging/io.iris.daemon.plist`
Expected: `packaging/io.iris.daemon.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add packaging/io.iris.daemon.plist
git commit -m "chore(phase-7): ThrottleInterval=30 on daemon LaunchAgent (SPECS §3.3)"
```

---

## Task 9: Postinstall — relance `--first-launch`

**Files:**
- Modify: `packaging/scripts/postinstall`

- [ ] **Step 1: Ajouter la relance** — dans le bloc `if [ -n "$INSTALL_USER" ] ...`, après la ligne `sudo -u "$INSTALL_USER" mkdir -p "$USER_HOME/Library/Application Support/iris"`, ajouter :
```bash
    # Phase 7 : enregistrer les services SMAppService dès l'install (auto-start).
    # L'app détecte --first-launch et appelle register() pour irisd + login-item.
    sudo -u "$INSTALL_USER" /usr/bin/open -a "/Applications/Iris.app" --args --first-launch
```

Mettre aussi à jour le commentaire d'en-tête : remplacer `# PAS d'auto-start (Phase 7).` par `# Auto-start (Phase 7) : relance Iris.app --first-launch sous l'utilisateur réel.`

- [ ] **Step 2: Vérifier la syntaxe shell**

Run: `bash -n packaging/scripts/postinstall`
Expected: aucune sortie (syntaxe valide).

- [ ] **Step 3: Commit**

```bash
git add packaging/scripts/postinstall
git commit -m "chore(phase-7): postinstall triggers Iris.app --first-launch"
```

---

## Task 10: Vérification globale + PR

**Files:** aucun (vérification + ouverture PR)

- [ ] **Step 1: Build + tests + lint (headless)**

```bash
swift build
swift test
swift-format lint --strict --recursive Sources Tests
```
Expected: build OK ; tous tests verts (462 = 455 + 7) ; lint clean.

- [ ] **Step 2: Build app**

Run: `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Pousser la branche**

```bash
git push -u origin feat/phase-7-autostart
```

- [ ] **Step 4: Ouvrir la PR** avec checklist de smoke testing (CLAUDE.md §8)

```bash
gh pr create --base main --head feat/phase-7-autostart \
  --title "feat(phase-7): auto-start daemon + app via SMAppService" \
  --body "$(cat <<'EOF'
## Phase 7 — Auto-start (SMAppService)

Enregistre `irisd` (LaunchAgent) et `Iris.app` (login-item) via `SMAppService`,
auto au premier lancement (`--first-launch`) + toggles dans Settings.

Spec: `docs/superpowers/specs/2026-06-06-phase-7-autostart-design.md`
Plan: `docs/superpowers/plans/2026-06-06-phase-7-autostart.md`

### Smoke testing (au poste — requiert .pkg installé dans /Applications)
- [ ] `./packaging/build-pkg.sh` produit un `.pkg` signé ; installation dans `/Applications`
- [ ] Après postinstall : `launchctl print gui/$(id -u)/io.iris.daemon` montre le service ; `iris doctor` round-trip OK
- [ ] Réglages Système → Éléments de connexion : `Iris` (login-item) ET le service en arrière-plan présents
- [ ] Settings → « Launch at login » : les deux toggles reflètent l'état réel
- [ ] Toggle daemon off → on : `launchctl` confirme arrêt puis redémarrage
- [ ] Toggle app off → on : login-item disparaît puis réapparaît dans Réglages Système
- [ ] Cas `requiresApproval` : bouton « Open Login Items… » ouvre le bon panneau
- [ ] **Reboot** : `irisd` relancé par launchd + `Iris.app` relancée (status item réapparaît)
- [ ] Aucun secret/valeur en log ou UI (invariant transverse)

### Vérifié headless
- [x] `swift build` + `swift test` (7 tests AutoStart ajoutés) + `swift-format --strict` verts
- [x] `xcodebuild -scheme IrisApp` build OK
EOF
)"
```
Expected: PR créée.

- [ ] **Step 5: Surveiller le CI + revue Gemini** (CLAUDE.md §8) — oracle CI = API check-runs, pas `gh pr checks`.

---

## Task 11: Smoke poste (manuel) + merge

**Files:** aucun (validation réelle + merge sur OK user)

> Cette task n'est PAS un commit. C'est la validation physique de la checklist PR. Elle exige le `.pkg` installé dans `/Applications` (l'auto-start n'est pas testable depuis un build dev). Rappel mémoire : **signer après le dernier build, ne plus rebuilder** ; purger une éventuelle collision LaunchServices (`mdfind "kMDItemCFBundleIdentifier == 'io.iris.app'"` doit lister 1 bundle).

- [ ] **Step 1:** Cocher chaque item de la checklist smoke de la PR (§ smoke testing) au fur et à mesure, avec preuves (`launchctl print`, captures Réglages Système, comportement post-reboot).
- [ ] **Step 2:** Traiter la revue Gemini (appliquer ou refuser factuellement chaque commentaire).
- [ ] **Step 3:** Merge `--squash` sur confirmation explicite de l'utilisateur, une fois les 3 conditions §8 réunies (Gemini traité, CI vert + smoke 8/8 cochés).

---

## Self-Review

**Spec coverage** (vs `2026-06-06-phase-7-autostart-design.md`) :
- §3 décisions → daemon+app (Tasks 1/5/7), auto+toggles (Tasks 6/7/9), unregister via toggles (Task 4), toggles indépendants (Task 4 tests), ThrottleInterval (Task 8), au poste (Task 11). ✓
- §4 faits API → mapping `status`/`register`/`unregister`/`openSystemSettingsLoginItems` (Task 5). ✓
- §5.1 seam unifié → Task 1 ; §5.2 AppModel → Tasks 3-5 ; §5.3 SettingsTab → Task 6 ; §5.4 --first-launch → Task 7 ; §5.5 packaging → Tasks 8-9. ✓
- §7.1 tests headless (refresh, register/unregister, idempotence, indépendance, erreur, anti-test-vide via `fake.calls`) → Tasks 3-5 ; §7.2 smoke → Tasks 10-11. ✓
- §8 hors-scope respecté (pas de Quit & Uninstall, pas de CA, `agent` pas `daemon`). ✓
- §9 DoD → Task 10 (build/test/lint/CI) + Task 11 (smoke/reboot). ✓

**Placeholder scan** : aucun TBD/TODO/« add error handling » ; tout code et toute commande sont explicites. Le squelette de Task 3 Step 3 est intentionnel et remplacé en Task 5 Step 3b (noté). ✓

**Type consistency** : `AutoStartTarget`/`AutoStartStatus`/`AutoStartControlling` cohérents Task 1↔2↔3↔5↔6↔7. `setAutoStart(_:enabled:)`, `refreshAutoStart()`, `openLoginItemsSettings()` identiques entre AppModel (Tasks 3-5) et appelants (Task 6). `daemonPlistName = "io.iris.daemon.plist"` = nom embarqué par `build-pkg.sh` (vérifié) = `agent(plistName:)` (Task 5). Toggle binding `status == .enabled` cohérent avec l'état exposé. ✓
