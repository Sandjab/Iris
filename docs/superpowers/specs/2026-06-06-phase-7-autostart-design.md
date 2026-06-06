# Phase 7 — Auto-start (SMAppService) — Design

> Date : 2026-06-06
> Branche : `feat/phase-7-autostart`
> Statut : design validé, en attente du plan d'implémentation.

## 1. Objectif

Rendre IRIS autonome après installation : plus aucun lancement manuel.

1. **Daemon LaunchAgent** — l'app enregistre `irisd` auprès de `launchd` (`SMAppService.agent`), qui le démarre au login et le maintient en vie.
2. **App login-item** — la menu-bar `Iris.app` se relance à l'ouverture de session (`SMAppService.mainApp`).

Cette phase couvre CLAUDE.md §12 (« Phase 7 — LaunchAgent + SMAppService integration ») et absorbe la carte historiquement étiquetée « 6.4 » (app login-item, jamais faite), les deux usages partageant le même framework, le même foyer UI et le même geste d'uninstall.

## 2. État de départ (vérifié)

- **Débloqué par les phases 9a/9b** : bundle `Iris.app` signé Developer ID + notarisé, `irisd` embarqué dans `Contents/MacOS/`, plist `io.iris.daemon.plist` déjà copiée dans `Contents/Library/LaunchAgents/` par `packaging/build-pkg.sh`.
- **Aucun code SMAppService** n'existe (`grep -rn SMAppService Sources/` = 0).
- **`packaging/scripts/postinstall`** crée `~/Library/Application Support/iris` sous l'utilisateur réel mais marque explicitement « PAS d'auto-start (Phase 7) ».
- **Foyer UI prêt** : `SettingsTab` possède déjà un `GroupBox "Certificate Authority"` (état + boutons Install/Uninstall) câblé via le seam `CATrustInstalling` → `AppModel.installCA/uninstallCA`. C'est le patron répliqué ici.

## 3. Décisions de scope (tranchées)

| Décision | Choix retenu |
| --- | --- |
| Périmètre | **Les deux services** : daemon LaunchAgent (`agent().register()`) + app login-item (`mainApp.register()`). |
| Déclenchement | **Auto au 1er lancement** (`--first-launch` via postinstall) **+ toggles** dans Settings (état réel + activer/désactiver). |
| Uninstall | **`unregister()` via les toggles** uniquement. Pas de bouton « Quit & Uninstall » global (workflow destructeur — purge cert + secrets Keychain — reporté à une phase dédiée, cf. CLAUDE.md §10). |
| Couplage des toggles | **Indépendants** : daemon et login-item se basculent séparément. |
| `ThrottleInterval` | **Ajouté** au plist daemon (`30`, anti-boucle de crash, SPECS §3.3). |
| Environnement de la session | **Au poste** : vérification de bout en bout possible cette session. |

## 4. Faits API vérifiés (sosumi, doc Apple)

`SMAppService` — `class`, **macOS 13.0+** (conforme à la cible projet) :

- `SMAppService.mainApp` — l'app principale comme login-item.
- `SMAppService.agent(plistName:)` — LaunchAgent (user-domain, per-session). **On utilise `agent`, PAS `daemon`** (qui est root-domain — SPECS §17.1).
- `register()` / `unregister()` — *throwing*. La doc précise : « Registers the service so it can begin launching **subject to user approval** ».
- `status` → `SMAppService.Status` : `.notRegistered`, `.enabled`, `.requiresApproval` (« successfully registered, but the user needs to take action in System Preferences »), `.notFound`.
- `openSystemSettingsLoginItems()` — ouvre Réglages Système → Éléments de connexion.

Conséquence design : même un `register()` réussi peut laisser le service en `.requiresApproval` ; l'UI doit traiter cet état comme distinct de `.enabled` et offrir un raccourci vers les Réglages Système.

## 5. Architecture

### 5.1 Seam unifié (`IrisAppCore`)

Un seul protocole `Sendable` couvrant les deux services, paramétré par un enum cible (DRY : une impl prod, un fake). Réplique de `CATrustInstalling`.

Nouveau dossier `Sources/IrisAppCore/AutoStart/` :

**`AutoStartService.swift`**
```swift
public enum AutoStartTarget: Sendable, CaseIterable {
    case daemon   // SMAppService.agent(plistName: "io.iris.daemon.plist")
    case app      // SMAppService.mainApp
}

/// Maison (pas SMAppService.Status) : garde IrisAppCore testable sans dépendre
/// du contexte bundle, exactement comme `caTrusted: Bool?`.
public enum AutoStartStatus: Sendable {
    case enabled            // tourne / éligible
    case requiresApproval   // enregistré, mais l'utilisateur doit autoriser en Réglages Système
    case notRegistered      // off
    case notFound           // plist/bundle introuvable (anomalie)
    case unknown            // état illisible
}

/// Seam sur l'API SMAppService (in-process, non testable hors bundle installé).
public protocol AutoStartControlling: Sendable {
    func status(_ target: AutoStartTarget) -> AutoStartStatus
    func register(_ target: AutoStartTarget) throws
    func unregister(_ target: AutoStartTarget) throws
    func openLoginItemsSettings()
}
```

**`SystemAutoStartService.swift`** (impl prod, smoke-only)
```swift
import ServiceManagement

public struct SystemAutoStartService: AutoStartControlling {
    public init() {}
    // mappe AutoStartTarget → SMAppService.{agent(plistName:), mainApp}
    // mappe SMAppService.Status → AutoStartStatus
    // register/unregister → service.register()/unregister()
    // openLoginItemsSettings → SMAppService.openSystemSettingsLoginItems()
}
```

`SystemAutoStartService` réside dans `IrisAppCore` (qui importe déjà des frameworks système via `IrisKit`). En test, `Bundle.main` = le test-runner, donc l'impl prod n'est jamais exécutée : seul le `Fake` l'est — symétrique à `SystemCATrustInstaller`.

### 5.2 `AppModel` (réplique de la box CA)

- État publié :
  ```swift
  @Published public var daemonAutoStart: AutoStartStatus?
  @Published public var appAutoStart: AutoStartStatus?
  ```
- Seam injecté dans `init` :
  ```swift
  public init(..., autoStart: AutoStartControlling = SystemAutoStartService())
  ```
- Méthodes :
  ```swift
  public func refreshAutoStart()                                  // lit status(.daemon)/status(.app)
  public func setAutoStart(_ target: AutoStartTarget, enabled: Bool) async throws
      // idempotent (skip si déjà dans l'état voulu), register/unregister hors main-actor
      // via Task.detached, puis refresh — calque exact d'installCA/uninstallCA.
  ```
  `refreshAutoStart()` est synchrone (lecture de `status`, non bloquante) ; `setAutoStart` est `async` (l'appel register/unregister peut bloquer sur l'IPC launchd → `Task.detached`).

### 5.3 `SettingsTab` — `GroupBox "Launch at login"`

Inséré sous `caBox()`, même grammaire visuelle. Deux lignes indépendantes :

- **Background service (irisd)** : libellé d'état + `Toggle`.
- **Menu bar app (Iris)** : libellé d'état + `Toggle`.

Rendu d'état par ligne :
- `.enabled` → vert « On ».
- `.notRegistered` → secondaire « Off ».
- `.requiresApproval` → orange « Needs approval » + bouton « Open Login Items… » → `model.openLoginItemsSettings()`.
- `.notFound` / `.unknown` → secondaire, toggle désactivé (anomalie), message diagnostic.

Le `Toggle` est piloté par un `Binding` calqué sur le `Picker` `on_exfil_attempt` existant : `get` lit `model.{daemon,app}AutoStart == .enabled`, `set` appelle `model.setAutoStart(target, enabled:)`. Erreurs affichées via le `errorText` existant de `SettingsTab`. Refresh dans le `.task { reload() }` existant.

### 5.4 Premier lancement (`--first-launch`)

- `AppDelegate.applicationDidFinishLaunching` détecte `--first-launch` dans `CommandLine.arguments`. Si présent : `register(.daemon)` + `register(.app)` best-effort (idempotent ; échec loggé, non bloquant — l'utilisateur garde les toggles).
- Détection effectuée **après** la garde multi-instance existante.
- **Périmètre strict** : la phase ne touche QUE SMAppService. La génération/install de la CA reste assurée par l'existant (daemon au démarrage + box CA dans Settings) ; `--first-launch` ne fait pas de CA ici.

### 5.5 Packaging

- **`packaging/io.iris.daemon.plist`** : ajout de
  ```xml
  <key>ThrottleInterval</key>
  <integer>30</integer>
  ```
  (SPECS §3.3 — borne la boucle de relance si une 2e instance échoue à bind).
- **`packaging/scripts/postinstall`** : ajout, après la création du dossier de support, de
  ```bash
  sudo -u "$INSTALL_USER" /usr/bin/open -a "/Applications/Iris.app" --args --first-launch
  ```
  (le postinstall tourne en root ; on relance sous l'utilisateur réel déjà résolu — même garde que pour `mkdir`).

## 6. Flux de données

1. **Install** : `.pkg` copie `Iris.app` dans `/Applications` → `postinstall` (root) résout l'utilisateur réel → `open -a Iris.app --args --first-launch` (sous l'utilisateur).
2. **1er lancement** : `AppDelegate` voit `--first-launch` → `register(.daemon)` (→ `launchd` démarre `irisd`, qui génère sa CA) + `register(.app)`. macOS peut afficher « Iris a été ajouté aux éléments de connexion ».
3. **Settings** : `SettingsTab.reload()` → `model.refreshAutoStart()` → toggles reflètent `status(.daemon)/status(.app)`. L'utilisateur peut basculer chaque service ; `.requiresApproval` → bouton vers Réglages Système.
4. **Reboot** : `launchd` relance `irisd` (LaunchAgent `RunAtLoad`) ; macOS relance `Iris.app` (login-item).

## 7. Tests

### 7.1 Headless (`swift test`, CI)
- **`FakeAutoStartService`** (sous `Tests/IrisAppCoreTests/Mocks/`, calqué sur `FakeCATrustInstaller`) : statut scriptable par cible, enregistre les appels register/unregister, peut simuler `throw` et `requiresApproval`.
- **`AutoStartTests`** sur `AppModel` :
  - `refreshAutoStart` recopie le statut du seam vers `daemonAutoStart`/`appAutoStart`.
  - `setAutoStart(enabled: true/false)` appelle register/unregister sur la **bonne** cible et met l'état à jour.
  - **Idempotence** : `setAutoStart(enabled: true)` alors que déjà `.enabled` n'appelle pas register (skip), calque du `if caTrusted == true { return }`.
  - Indépendance des cibles : basculer `.app` ne touche pas `.daemon`.
  - Propagation d'erreur : un `throw` du seam remonte et laisse l'état cohérent.
  - **Anti-test-vide (Rule 9)** : chaque test vérifie l'effet observable (cible + sens de l'appel enregistré dans le fake), pas seulement l'absence de crash.

### 7.2 Smoke poste (checklist PR, manuel)
1. `./packaging/build-pkg.sh` → `.pkg` signé ; install dans `/Applications`.
2. Après postinstall : `irisd` démarré par `launchd` — `launchctl print gui/$(id -u)/io.iris.daemon` montre le service ; `iris doctor` round-trip OK.
3. Réglages Système → Éléments de connexion : `Iris` (login-item) **et** le service en arrière-plan présents.
4. Settings → « Launch at login » : les deux toggles reflètent l'état ; off→on→off fonctionne (vérifier `launchctl` + Réglages Système à chaque bascule).
5. Cas `.requiresApproval` : bouton « Open Login Items… » ouvre le bon panneau.
6. **Reboot** : `irisd` relancé par `launchd`, `Iris.app` relancée (status item réapparaît).
7. Redaction maintenue, aucun secret en log (invariant transverse).

## 8. Hors-scope (explicite)

- **« Quit & Uninstall » global** (SPECS §18.3 : purge cert + suppression secrets Keychain + Finder) — workflow destructeur, phase dédiée.
- **CA** : génération/install/uninstall déjà couvertes (daemon + box CA de 6.3b) — non touchées.
- **`SMAppService.daemon` (root LaunchDaemon)** — on reste en `agent` (user-domain), conforme SPECS §17.1.
- **Migration d'un éventuel ancien login-item legacy** — installation neuve, pas de legacy.

## 9. Critères de réussite (DoD)

1. `swift build` + `swift test` verts (tests headless du seam/AppModel ajoutés), `swift-format lint --strict` clean.
2. CI verte (build-test + xcode-build macOS-15).
3. Onglet Settings : section « Launch at login » fonctionnelle (état + toggles + raccourci approbation).
4. Smoke poste 7/7 (cf. §7.2), **dont le reboot** : daemon et app relancés automatiquement.
5. Aucun secret/valeur en log ou UI (invariant transverse).

## 10. Fichiers touchés (prévision)

**Créer**
- `Sources/IrisAppCore/AutoStart/AutoStartService.swift` (enums + protocole)
- `Sources/IrisAppCore/AutoStart/SystemAutoStartService.swift` (impl prod, `import ServiceManagement`)
- `Tests/IrisAppCoreTests/Mocks/FakeAutoStartService.swift`
- `Tests/IrisAppCoreTests/AutoStartTests.swift`

**Modifier**
- `Sources/IrisAppCore/AppModel.swift` (état + seam injecté + `refreshAutoStart`/`setAutoStart`)
- `IrisApp/IrisApp/SettingsTab.swift` (GroupBox « Launch at login »)
- `IrisApp/IrisApp/AppDelegate.swift` (détection `--first-launch`)
- `packaging/io.iris.daemon.plist` (`ThrottleInterval=30`)
- `packaging/scripts/postinstall` (relance `--first-launch`)

> Note CI : l'ajout d'un `.swift` à la cible Xcode `IrisApp` n'exige aucune édition `.pbxproj` (groupe `PBXFileSystemSynchronizedRootGroup`). Les fichiers de `Sources/IrisAppCore/` sont compilés par SwiftPM. Le seul juge des changements de la cible app reste le CI macOS-15.
