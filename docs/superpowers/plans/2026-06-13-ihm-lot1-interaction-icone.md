# Lot 1 — Interaction de l'icône menu-bar — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrichir le menu de l'icône `NSStatusItem` (About / Settings… / Quit) et lever l'ambiguïté du bouton « Pause » de l'onglet Logs, sans toucher à la navigation du panneau.

**Architecture:** Modifications localisées dans deux vues AppKit/SwiftUI de la cible `IrisApp` : `AppDelegate` (status item + menu) et `LogsTab` (libellé). Aucun changement de modèle, d'IPC ou de logique daemon. Spec : `docs/superpowers/specs/2026-06-13-ihm-lot1-interaction-icone-design.md`.

**Tech Stack:** Swift, AppKit (`NSMenu`, `NSStatusItem`, `NSApplication`), SwiftUI (`Toggle`). Build via `xcodebuild -scheme IrisApp`.

> **Note vérification (écart assumé au TDD)** : ce lot ne modifie que des vues de la cible Xcode `IrisApp`, qui n'a **aucun harnais de tests UI** dans ce projet (les tests SPM couvrent `IrisKit`/`IrisAppCore`). Tester la structure d'un `NSMenu` à 3 items serait un test tautologique sans valeur (anti Rule 9). La vérification est donc **compilation (`xcodebuild`) + smoke visuel** (checklist en Task 3), conformément au spec §5.

---

## File structure

| Fichier | Rôle | Changement |
|---|---|---|
| `IrisApp/IrisApp/LogsTab.swift` | onglet Logs | libellé du toggle de gel (ligne 42) |
| `IrisApp/IrisApp/AppDelegate.swift` | status item + menu | menu enrichi + 2 nouveaux selectors |

Aucun fichier créé. `Info.plist` : vérification conditionnelle au smoke (Task 3), pas d'édition planifiée a priori.

---

## Task 1 : Relabel du gel de flux Logs (V2)

**Files:**
- Modify: `IrisApp/IrisApp/LogsTab.swift:42`

- [ ] **Step 1 : Modifier le libellé**

Remplacer (ligne 42) :
```swift
            Toggle("Pause", isOn: pauseBinding).toggleStyle(.button)
```
par :
```swift
            Toggle("Freeze", isOn: pauseBinding).toggleStyle(.button)
```
*(Seul le libellé change ; `pauseBinding` / `streamPaused` / `setStreamPaused` sont intacts.)*

- [ ] **Step 2 : Compiler**

Run :
```bash
xcodebuild -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`.

- [ ] **Step 3 : Commit**

```bash
git add IrisApp/IrisApp/LogsTab.swift
git commit -m 'fix(ihm): "Freeze" pour le gel du flux Logs (distinct du Pause daemon)'
```

---

## Task 2 : Menu de l'icône — About / Settings… / Quit (R1 + R2-A)

**Files:**
- Modify: `IrisApp/IrisApp/AppDelegate.swift` (handleClick `:132-146`, showQuitMenu `:148-158`, + 2 méthodes)

- [ ] **Step 1 : Rebrancher `handleClick` sur le nouveau menu**

Dans `handleClick(_:)`, remplacer l'appel (ligne ~142) :
```swift
            showQuitMenu(from: sender)
```
par :
```swift
            showStatusMenu(from: sender)
```

- [ ] **Step 2 : Remplacer `showQuitMenu` par `showStatusMenu`**

Remplacer toute la méthode `showQuitMenu(from:)` (`:148-158`) par :
```swift
    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About Iris", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Iris", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // popUp(positioning:at:in:) reste le remplacement non-déprécié de popUpMenu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }
```

- [ ] **Step 3 : Ajouter les deux actions**

Ajouter ces deux méthodes dans `AppDelegate` (à côté de `quit()`, `:212`) :
```swift
    @objc private func openSettings() {
        appModel.selectedTab = .settings
        panelController?.show()
    }

    @objc private func showAbout() {
        // L'app est LSUIElement non-activante : activer avant pour que le panneau
        // About standard passe au premier plan.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
```
*(Vérifié : `appModel` est `private let appModel = AppModel()` `:16` ; `selectedTab: AppModel.Tab` avec cas `.settings` — utilisé en binding dans `BrokerPanelView.swift:16` ; `panelController?.show()` existe `MainPanelController.swift:26`.)*

- [ ] **Step 4 : Compiler**

Run :
```bash
xcodebuild -scheme IrisApp -configuration Debug build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`. (Si « Cannot find 'selectedTab' / '.settings' » : confirmer le nom du cas dans `AppModel.Tab` — oracle = le compilateur, pas SourceKit.)

- [ ] **Step 5 : Commit**

```bash
git add IrisApp/IrisApp/AppDelegate.swift
git commit -m 'feat(ihm): menu de l'\''icône — About / Settings… / Quit (R1, R2-A)'
```

---

## Task 3 : Vérification — build complet + smoke visuel

**Files:** aucun (sauf action conditionnelle Info.plist ci-dessous).

- [ ] **Step 1 : Build release**

Run :
```bash
xcodebuild -scheme IrisApp -configuration Release build 2>&1 | tail -5
```
Expected : `** BUILD SUCCEEDED **`.

- [ ] **Step 2 : Lancer l'app buildée et smoke**

Lancer le `.app` produit (chemin via `xcodebuild -showBuildSettings -scheme IrisApp | grep -i BUILT_PRODUCTS_DIR`), puis vérifier la checklist du spec §5 :
- [ ] clic droit / ctrl+clic sur l'icône → menu `About Iris` · `Settings…` · ─ · `Quit Iris` ;
- [ ] clic gauche → ouvre/ferme le panneau (inchangé) ;
- [ ] « Settings… » → panneau ouvert **sur l'onglet Settings** (bascule si déjà ouvert ailleurs) ;
- [ ] « About Iris » → panneau About standard **au premier plan**, nom « Iris » + version corrects ;
- [ ] « Quit Iris » → quitte ;
- [ ] onglet Logs → bouton libellé **« Freeze »**, gèle toujours le flux (le toggle fige l'affichage) ;
- [ ] Pause daemon (HeaderBar) inchangé.

- [ ] **Step 3 : (Conditionnel) Info.plist About**

Si au Step 2 le panneau About affiche un **nom ou une version vide** :
```bash
xcodebuild -showBuildSettings -scheme IrisApp | grep -iE 'PRODUCT_NAME|MARKETING_VERSION|GENERATE_INFOPLIST'
```
- Si `GENERATE_INFOPLIST_FILE = YES` : le nom/version viennent de `PRODUCT_NAME` / `MARKETING_VERSION` (déjà définis pour une app notarisée) — vérifier qu'ils sont non vides.
- Pour ajouter le copyright (optionnel, cosmétique) : build setting `INFOPLIST_KEY_NSHumanReadableCopyright = "© 2026 Iris"` (ou éditer la clé `NSHumanReadableCopyright` si un `Info.plist` physique existe).
- Si rien à corriger (nom+version OK), **ne rien faire** (YAGNI).

- [ ] **Step 4 : (si Step 3 a modifié quelque chose) Commit**

```bash
# Committer UNIQUEMENT le fichier modifié — PAS `git add -A`
# (le working tree peut contenir des modifs non liées, ex. docs/manual/manuel.html).
git add IrisApp/IrisApp/Info.plist   # ou le .xcodeproj si la clé est en build setting
git commit -m "chore(ihm): copyright dans le panneau About"
```

---

## Self-review (auteur du plan)

- **Couverture spec** : R2-A (menu secondary-click) → Task 2 ; R1 (« Settings… » → onglet Settings) → Task 2 Step 3 ; V2 (relabel) → Task 1 ; About standard → Task 2 Step 3 ; Info.plist → Task 3 Step 3 ; smoke §5 → Task 3 Step 2. Hors-périmètre (découvrabilité Quit surface, navigation, V3/V4) : absents du plan — correct.
- **Placeholders** : aucun « TBD » ; le conditionnel Info.plist fournit les valeurs/commandes exactes.
- **Cohérence des types** : `selectedTab`/`.settings`, `panelController?.show()`, `#selector(showAbout)`/`#selector(openSettings)`/`#selector(quit)` cohérents entre steps.

---

## Notes d'exécution

- Toujours sur la branche `feat/ihm-lot1-interaction-icone`.
- Avant PR : `swift build` + `swift test` (cibles SPM, non impactées mais doivent rester vertes) + `swift-format`, puis PR avec la checklist de smoke (Task 3 Step 2) comme checklist de smoke testing de la PR (convention §8).
- Oracle final de compilation IrisApp = CI macOS-15.
