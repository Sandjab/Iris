# Fenêtre déplaçable menu-bar — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer le `NSPopover` de l'app menu-bar par une vraie fenêtre (`NSPanel`) déplaçable, redimensionnable, flottante et non-activante.

**Architecture:** Le contenu SwiftUI existant est réutilisé tel quel (renommé `PopoverView` → `BrokerPanelView`). Un nouveau contrôleur AppKit mince (`MainPanelController`) possède un `NSPanel` non-activant et l'expose via `show()` / `toggle()`. `AppDelegate` perd toute la machinerie popover (popover, global-monitor outside-click, open/close/toggle) au profit du contrôleur.

**Tech Stack:** Swift, AppKit (`NSPanel`, `NSHostingController`), SwiftUI, app `LSUIElement` (cible Xcode `IrisApp`).

---

## Note de méthode — pourquoi pas de TDD ici

Ce plan touche **uniquement** de la glue de présentation AppKit (configuration d'un `NSPanel`, câblage de clics). Il n'y a aucune logique métier extractible : aucun `XCTest` ne pourrait échouer sur un changement de comportement réel sans piloter une vraie fenêtre AppKit. Conformément à Rule 9 (un test qui ne peut pas échouer est faux), on **n'invente pas** de tests unitaires.

La vérification repose sur trois piliers, à chaque commit puis en fin de plan :
1. **Compilation** locale `xcodebuild -scheme IrisApp` (catche erreurs de syntaxe/type) — pré-vol.
2. **Gate CI `xcodebuild` macOS-15** = l'**oracle** pour la cible IrisApp (la toolchain locale, plus récente, peut passer à tort ; un échec local reste un vrai échec).
3. **`swift test`** de non-régression (IrisAppCore est intact — doit rester vert).
4. **Checklist de smoke manuelle au poste** (Task 5) pour le comportement réel de la fenêtre.

Aucun fichier `.swift` ajouté/renommé n'exige d'édition de `project.pbxproj` : la cible `IrisApp` utilise un `PBXFileSystemSynchronizedRootGroup` (découverte automatique).

---

## Structure des fichiers

| Fichier | Action | Responsabilité |
|---|---|---|
| `IrisApp/IrisApp/PopoverView.swift` → `BrokerPanelView.swift` | Renommer + éditer | Vue SwiftUI racine de l'IHM (inchangée hormis nom + frame flexible) |
| `IrisApp/IrisApp/MainPanelController.swift` | Créer | Hôte AppKit : possède le `NSPanel` non-activant, `show()`/`toggle()`/`isVisible` |
| `IrisApp/IrisApp/AppDelegate.swift` | Modifier | Retire la machinerie popover, instancie + câble `MainPanelController` |

---

## Task 1 : Renommer `PopoverView` → `BrokerPanelView` + frame flexible

Le rename d'abord, en gardant le code **compilable** : le `NSPopover` reste en place dans `AppDelegate` mais héberge désormais `BrokerPanelView`.

**Files:**
- Rename: `IrisApp/IrisApp/PopoverView.swift` → `IrisApp/IrisApp/BrokerPanelView.swift`
- Modify: `BrokerPanelView.swift` (nom du struct + `.frame`)
- Modify: `IrisApp/IrisApp/AppDelegate.swift` (référence au rootView, ligne ~101)

- [ ] **Step 1 : Renommer le fichier (en conservant l'historique git)**

```bash
git mv IrisApp/IrisApp/PopoverView.swift IrisApp/IrisApp/BrokerPanelView.swift
```

- [ ] **Step 2 : Renommer le struct**

Dans `IrisApp/IrisApp/BrokerPanelView.swift`, remplacer :

```swift
struct PopoverView: View {
```

par :

```swift
struct BrokerPanelView: View {
```

- [ ] **Step 3 : Rendre le frame flexible (suit le redimensionnement)**

Dans `IrisApp/IrisApp/BrokerPanelView.swift`, remplacer la dernière ligne du `body` du struct racine :

```swift
        .frame(width: 480, height: 600)
```

par :

```swift
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
```

- [ ] **Step 4 : Mettre à jour la seule référence dans AppDelegate**

Dans `IrisApp/IrisApp/AppDelegate.swift`, remplacer :

```swift
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(admin: admin).environmentObject(appModel)
        )
```

par :

```swift
        popover.contentViewController = NSHostingController(
            rootView: BrokerPanelView(admin: admin).environmentObject(appModel)
        )
```

- [ ] **Step 5 : Compiler (pré-vol local)**

Run : `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5`
Expected : `** BUILD SUCCEEDED **`

- [ ] **Step 6 : Lint**

Run : `swift-format lint IrisApp/IrisApp/BrokerPanelView.swift`
Expected : aucune sortie (clean)

- [ ] **Step 7 : Commit**

```bash
git add IrisApp/IrisApp/BrokerPanelView.swift IrisApp/IrisApp/AppDelegate.swift
git commit -m "refactor(app): rename PopoverView→BrokerPanelView + frame redimensionnable"
```

---

## Task 2 : Créer `MainPanelController`

Nouveau fichier autonome. Il référence `BrokerPanelView` (existe depuis Task 1) mais n'est pas encore câblé dans `AppDelegate` — il compile néanmoins (type valide, inutilisé).

**Files:**
- Create: `IrisApp/IrisApp/MainPanelController.swift`

- [ ] **Step 1 : Écrire le contrôleur**

Créer `IrisApp/IrisApp/MainPanelController.swift` avec exactement :

```swift
import AppKit
import IrisAppCore
import SwiftUI

/// Hôte AppKit de l'IHM du broker (`BrokerPanelView`) dans un `NSPanel` déplaçable,
/// redimensionnable, flottant et **non-activant**. Remplace l'ancien `NSPopover` ancré au
/// status item : le panneau se déplace n'importe où, se redimensionne, et reste ouvert pendant
/// que l'utilisateur travaille dans une autre app (il ne vole pas le focus clavier). Créé
/// paresseusement au premier affichage, puis retenu pour la durée du process.
@MainActor
final class MainPanelController {
    private let admin: AdminCalling
    private let appModel: AppModel
    private var panel: NSPanel?

    init(admin: AdminCalling, appModel: AppModel) {
        self.admin = admin
        self.appModel = appModel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Affiche le panneau et l'amène devant SANS le rendre key : un panneau non-activant ne
    /// vole pas le focus clavier (l'utilisateur continue à taper dans son terminal). Les champs
    /// texte prennent le focus seulement au clic (`becomesKeyOnlyIfNeeded`).
    func show() {
        makePanelIfNeeded().orderFront(nil)
    }

    /// Bascule la visibilité : masque si visible, affiche sinon.
    func toggle() {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingController(
            rootView: BrokerPanelView(admin: admin).environmentObject(appModel)
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Iris"
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        // NSPanel masque par défaut à la désactivation de l'app ; on le garde visible au-dessus
        // du terminal/éditeur.
        panel.hidesOnDeactivate = false
        // Panneau non-activant : ne devient key (focus clavier) que quand un champ texte
        // (hit view `needsPanelToBecomeKey == true`) est cliqué.
        panel.becomesKeyOnlyIfNeeded = true
        // Le bouton fermer masque la fenêtre (instance retenue, réaffichée au clic icône).
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 420, height: 480)

        // Persiste position + taille entre ouvertures et redémarrages. `center()` uniquement
        // s'il n'y a pas encore de frame sauvée (tout premier lancement).
        panel.setFrameAutosaveName("IrisBrokerPanel")
        if !panel.setFrameUsingName("IrisBrokerPanel") {
            panel.center()
        }

        self.panel = panel
        return panel
    }
}
```

- [ ] **Step 2 : Compiler (pré-vol local)**

Run : `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5`
Expected : `** BUILD SUCCEEDED **`

- [ ] **Step 3 : Lint**

Run : `swift-format lint IrisApp/IrisApp/MainPanelController.swift`
Expected : aucune sortie (clean)

- [ ] **Step 4 : Commit**

```bash
git add IrisApp/IrisApp/MainPanelController.swift
git commit -m "feat(app): MainPanelController — hôte NSPanel non-activant pour l'IHM broker"
```

---

## Task 3 : Câbler `AppDelegate` sur le panneau, retirer le popover

Retire la machinerie popover et branche `MainPanelController`.

**Files:**
- Modify: `IrisApp/IrisApp/AppDelegate.swift`

- [ ] **Step 1 : Mettre à jour le commentaire de `defaultAdminSocketPath()`**

Remplacer :

```swift
/// Module-internal so `PopoverView` reuses it without duplicating the literal.
```

par :

```swift
/// Module-internal so `MainPanelController` reuses it without duplicating the literal.
```

- [ ] **Step 2 : Remplacer les propriétés popover par le contrôleur**

Remplacer :

```swift
    private var notifications: NotificationCoordinator?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var pulseWorkItem: DispatchWorkItem?
    private var popoverMonitor: Any?
```

par :

```swift
    private var notifications: NotificationCoordinator?
    private var statusItem: NSStatusItem?
    private var panelController: MainPanelController?
    private var cancellables: Set<AnyCancellable> = []
    private var pulseWorkItem: DispatchWorkItem?
```

- [ ] **Step 3 : Le clic sur notification affiche la fenêtre**

Remplacer :

```swift
        let coordinator = NotificationCoordinator(model: appModel) { [weak self] in
            self?.openPopover()
        }
```

par :

```swift
        let coordinator = NotificationCoordinator(model: appModel) { [weak self] in
            self?.panelController?.show()
        }
```

- [ ] **Step 4 : Remplacer la création du popover par le contrôleur**

Remplacer :

```swift
        let admin = AdminClient(socketPath: defaultAdminSocketPath())
        let eventsClient = EventsClient(port: 8899)

        let popover = NSPopover()
        // .applicationDefined (not .transient): a transient popover dismisses itself on the
        // mouseDown of the status button, then handleClick's mouseUp re-opens it — so a second
        // click never closes it. We own dismissal explicitly (re-click + outside-click monitor).
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 480, height: 600)
        popover.contentViewController = NSHostingController(
            rootView: BrokerPanelView(admin: admin).environmentObject(appModel)
        )
        self.popover = popover
```

par :

```swift
        let admin = AdminClient(socketPath: defaultAdminSocketPath())
        let eventsClient = EventsClient(port: 8899)

        // L'IHM du broker vit dans un panneau déplaçable, redimensionnable, flottant et
        // non-activant (créé paresseusement au premier clic). Il réutilise le client `admin`
        // commun à toute l'app et l'`appModel` partagé.
        panelController = MainPanelController(admin: admin, appModel: appModel)
```

- [ ] **Step 5 : Le clic gauche sur l'icône bascule le panneau**

Dans `handleClick(_:)`, remplacer le bloc `guard` :

```swift
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
```

par :

```swift
        guard let event = NSApp.currentEvent else {
            panelController?.toggle()
            return
        }
```

Puis, plus bas dans la même méthode, remplacer :

```swift
        if isSecondaryClick {
            showQuitMenu(from: sender)
        } else {
            togglePopover()
        }
```

par :

```swift
        if isSecondaryClick {
            showQuitMenu(from: sender)
        } else {
            panelController?.toggle()
        }
```

- [ ] **Step 6 : Supprimer les méthodes popover devenues mortes**

Supprimer intégralement ces trois méthodes (et leurs commentaires) :

```swift
    private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    // Extracted so the notification click handler can force the popover open (not toggle).
    private func openPopover() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // .applicationDefined never self-dismisses, so close on any click outside the app.
        // The status button is handled by handleClick; clicks inside the popover are local
        // events this global monitor never receives, so they don't dismiss it.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        if let monitor = popoverMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMonitor = nil
        }
    }
```

- [ ] **Step 7 : Vérifier qu'il ne reste aucune référence popover**

Run : `grep -n "popover\|Popover\|PopoverView" IrisApp/IrisApp/AppDelegate.swift`
Expected : aucune sortie

- [ ] **Step 8 : Compiler (pré-vol local)**

Run : `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build 2>&1 | tail -5`
Expected : `** BUILD SUCCEEDED **`

- [ ] **Step 9 : Lint**

Run : `swift-format lint IrisApp/IrisApp/AppDelegate.swift`
Expected : aucune sortie (clean)

- [ ] **Step 10 : Commit**

```bash
git add IrisApp/IrisApp/AppDelegate.swift
git commit -m "feat(app): remplace le NSPopover par la fenêtre déplaçable (MainPanelController)"
```

---

## Task 4 : Vérification build/lint/tests + pousser pour le gate CI

**Files:** aucun (vérification)

- [ ] **Step 1 : Non-régression IrisAppCore**

Run : `swift build && swift test 2>&1 | tail -15`
Expected : build OK, tous les tests verts (le compte courant ~462, inchangé — aucune logique touchée)

- [ ] **Step 2 : Lint global des fichiers touchés**

Run : `swift-format lint IrisApp/IrisApp/BrokerPanelView.swift IrisApp/IrisApp/MainPanelController.swift IrisApp/IrisApp/AppDelegate.swift`
Expected : aucune sortie (clean)

- [ ] **Step 3 : Build app complet (Release, comme le gate)**

Run : `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Release build 2>&1 | tail -5`
Expected : `** BUILD SUCCEEDED **`

- [ ] **Step 4 : Pousser la branche**

```bash
git push -u origin feat/menubar-movable-window
```

- [ ] **Step 5 : Vérifier le gate CI (oracle pour IrisApp)**

Le build local (toolchain récente) ne fait PAS foi pour la cible IrisApp. Surveiller les check-runs via l'API (pas `gh pr checks`, réputé stale) une fois la PR ouverte (Task 6) :

Run : `gh api repos/:owner/:repo/commits/$(git rev-parse HEAD)/check-runs --jq '.check_runs[] | {name, status, conclusion}'`
Expected : `xcode-build` (macOS-15) → `conclusion: success`

---

## Task 5 : Smoke manuel au poste (vérification comportementale)

**Files:** aucun (manuel ; requiert le Mac interactif — non faisable en remote)

Installer/lancer l'app construite, puis vérifier chaque item. Cocher dans la PR.

- [ ] Clic icône menu-bar → la fenêtre s'ouvre **centrée à l'écran** au tout premier lancement.
- [ ] Déplacer + redimensionner la fenêtre, fermer (bouton fermer), rouvrir (clic icône) → **position & taille conservées**.
- [ ] Quit complet de l'app (ctrl/clic droit → Quit) puis relancer → **position & taille conservées** (persistance disque).
- [ ] La fenêtre **flotte au-dessus** du terminal/éditeur quand on bascule dessus.
- [ ] On peut **taper dans le terminal** pendant que la fenêtre est visible → **pas de vol de focus** (la fenêtre ne devient pas key à l'ouverture).
- [ ] **Boutons/onglets répondent au clic** (Pause/Resume, changement d'onglet) sans activer Iris.
- [ ] **Édition d'un champ** (Add secret / Add rule) : cliquer dans le champ → curseur + saisie clavier OK dans le panneau.
- [ ] Clic gauche icône quand la fenêtre est visible → **la masque** (toggle) ; re-clic → la réaffiche.
- [ ] **Badge** `unreadAlertCount` (chiffre sur l'icône), **pulse** d'icône après substitution, **menu Quit** (ctrl/clic droit) : inchangés.
- [ ] Clic sur une **notification d'alerte** → ouvre / amène la fenêtre devant.

---

## Task 6 : PR + revue Gemini + merge

**Files:** aucun

- [ ] **Step 1 : Ouvrir la PR avec la checklist de smoke** (CLAUDE.md §8 — la checklist `- [ ]` est obligatoire pour la mergeabilité)

```bash
gh pr create --base main --head feat/menubar-movable-window \
  --title "feat(app): fenêtre déplaçable pour l'IHM menu-bar (remplace le NSPopover)" \
  --body "$(cat <<'EOF'
Remplace le NSPopover ancré au status item par un NSPanel déplaçable, redimensionnable,
flottant et non-activant. Spec : docs/superpowers/specs/2026-06-06-menubar-movable-window-design.md

## Smoke testing
- [ ] Fenêtre centrée au 1er lancement
- [ ] Position + taille persistent (fermeture/réouverture)
- [ ] Position + taille persistent (quit + relaunch)
- [ ] Flotte au-dessus du terminal/éditeur
- [ ] Pas de vol de focus (frappe terminal OK pendant fenêtre ouverte)
- [ ] Boutons/onglets répondent sans activer l'app
- [ ] Édition champ (Add secret / Add rule) OK
- [ ] Clic icône = toggle (masque/réaffiche)
- [ ] Badge + pulse + menu Quit inchangés
- [ ] Clic notification ouvre la fenêtre
EOF
)"
```

- [ ] **Step 2 : Attendre + traiter la revue Gemini** selon CLAUDE.md §8 (polling 1 min, arrêt après 10 min de silence, plafond 30 min). Pour chaque commentaire : appliquer+commit+répondre, OU refuser factuellement.

- [ ] **Step 3 : Merge sur confirmation explicite de l'utilisateur** (CLAUDE.md §8 — jamais de merge auto). Conditions : Gemini traité + CI vert + smoke 10/10 coché. Puis : `gh pr merge --squash`.

---

## Self-review (rédacteur du plan)

- **Couverture spec** : §3 approche → Task 2 (NSPanel) ; §4.1 contrôleur → Task 2 ; §4.2 config panneau → Task 2 (toutes propriétés présentes) ; §4.3 AppDelegate → Task 3 ; §4.4 rename + frame → Task 1 ; §4.5 policy `.accessory` inchangée (aucune action = correct, `IrisAppApp.swift` non touché) ; §4.6 toggle → Task 3 Step 5 ; §5 risque édition texte → Task 5 smoke ; §6 DoD → Tasks 4–6. Aucune lacune.
- **Placeholders** : aucun TBD/TODO ; tout le code est complet et littéral.
- **Cohérence des types** : `MainPanelController(admin:appModel:)` défini Task 2, appelé à l'identique Task 3 Step 4 ; `show()`/`toggle()`/`isVisible` définis Task 2, utilisés Task 3 ; `BrokerPanelView(admin:)` défini Task 1, utilisé Task 2. Cohérent.
