# Lot 2 — Fenêtre Réglages dédiée — Spec de design

> Deuxième lot du redesign IHM menu-bar (post-1.0). Source de vérité pour l'implémentation.
> Diagnostic : `docs/redesign-ihm-menubar.md` (findings R1, R3, V1). Lot 1 (mergé) : `2026-06-13-ihm-lot1-interaction-icone-design.md`.

## Objectif

Extraire **toute la configuration** du panneau menu-bar dans une **fenêtre Réglages dédiée à sidebar** (convention macOS « Réglages Système », ⌘,). Le panneau ne conserve que le **monitoring**. Cela lève la surcharge du mot « Settings » (R1 : un onglet *et* une notion de réglages) et amorce la cible **option (c)** du diagnostic (R3 : scinder monitoring et config).

Aucune logique daemon, IPC ou modèle nouvelle : on réorganise des vues SwiftUI existantes et on recâble l'ouverture des réglages.

## 1. Périmètre

**Dans le périmètre :**
- Une fenêtre Réglages (`NSWindow` normale, sidebar `NavigationSplitView`).
- Migration du contenu de `SettingsTab` (7 sections) vers la sidebar (regroupement en 4 sections + Uninstall).
- Retrait de l'onglet « Settings » du panneau (→ 5 onglets monitoring).
- Recâblage de l'item de menu « Settings… » (⌘,) pour ouvrir la fenêtre Réglages.

**Hors périmètre (lots ultérieurs) :**
- Refonte compacte/adaptative du panneau monitoring (V1 vide vertical, V6 hiérarchie Overview, R4 retrait du `StatusDot`) → lot ultérieur.
- Raccourci ⌘, **global** (hors menu ouvert) : l'app `LSUIElement` n'a pas de main menu ; le `keyEquivalent` du menu ne joue que menu ouvert. À traiter séparément si souhaité.
- Autres findings visuels (V3 host redondant, V5 empty states).

## 2. Architecture

### Nouveaux fichiers (`IrisApp/IrisApp/`)

| Fichier | Rôle |
|---|---|
| `SettingsWindowController.swift` | Hôte AppKit de la fenêtre Réglages — réplique du pattern `MainPanelController`, pour une `NSWindow` **normale activante**. |
| `SettingsWindow.swift` | Racine SwiftUI : `NavigationSplitView` (sidebar + détail), enum de section, état de sélection. |
| `SettingsSections.swift` | Les 5 vues de section (découpage isolé de `SettingsTab`) + le style partagé `SettingSection` (GroupBox). |

### Fichiers modifiés

| Fichier | Changement |
|---|---|
| `AppDelegate.swift` | Ajout d'un `settingsWindowController` (lazy, injecté `AppModel`+`AdminCalling` comme `panelController`) ; `openSettings()` ouvre la fenêtre au lieu de `selectedTab=.settings`. |
| `BrokerPanelView.swift` | Retrait de l'item `.settings` de la `TabBar` (→ 5 onglets) et du `case .settings` du switch de contenu. |
| `Sources/IrisAppCore/AppModel.swift` | Retrait de `.settings` de l'enum `Tab`. |

### Fichier supprimé

- `SettingsTab.swift` — son contenu migre dans `SettingsSections.swift` ; il n'est plus référencé une fois l'onglet retiré.

## 3. La fenêtre Réglages

`SettingsWindowController` (mirroir de `MainPanelController.swift`) :
- `NSWindow` `styleMask: [.titled, .closable, .miniaturizable, .resizable]`, titre **« Iris Settings »** (convention macOS « <App> Settings »).
- **Activante** (standard) : prend le focus clavier, apparaît en ⌘-Tab. C'est l'inverse assumé du panneau monitoring (non-activant, flottant) : configurer est une tâche délibérée, surveiller est passif.
- `contentViewController = NSHostingController(rootView: SettingsWindow(admin:).environmentObject(appModel))`.
- Single-instance retenue : `isReleasedWhenClosed = false` ; le bouton fermer masque (orderOut), `show()` ré-affiche et ramène devant (`makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps:)` via le garde `#available(macOS 14, *)` `activate()` établi au Lot 1).
- Position + taille persistées : `setFrameAutosaveName("IrisSettingsWindow")`, centrage géométrique au premier lancement (même calcul `visibleFrame` que le panneau, cf. [[reference-appkit-menubar-panel]]).
- `contentMinSize` raisonnable pour une sidebar (ex. 560×400).

## 4. Sidebar + sections (regroupement B)

`SettingsWindow` : `NavigationSplitView { sidebar } detail { section sélectionnée }`.

**Sidebar** — `List(selection:)` d'un enum `SettingsSection`, sélection `@State` (défaut `.general`). Quatre sections thématiques, puis **Uninstall isolé en bas** (action destructive séparée visuellement) :

| Sidebar | SF Symbol | Contenu (provenance `SettingsTab`) |
|---|---|---|
| **General** | `gearshape` | exfil policy (`security.on_exfil_attempt`) + max subs/min + keep backups |
| **Certificate** | `lock.shield` | trust CA + Install…/Uninstall… |
| **Integration** | `terminal` | Terminal (shell config) + Launch at login (toggles daemon + app) |
| **Advanced** | `slider.horizontal.3` | Connection (read-only : proxy/events/admin socket/log level/retention/ring) + Reveal config.json / Reload |
| *(séparateur)* | | |
| **Uninstall** | `trash` | Quit & Uninstall + dialogs de confirmation |

**Vues de détail** (`SettingsSections.swift`) — découpage *design-for-isolation* du `SettingsTab` monolithique. Chacune : `@EnvironmentObject model: AppModel`, état local minimal, et **délègue aux méthodes `AppModel` déjà existantes**. Reçoit `admin: AdminCalling` **seulement si elle appelle l'IPC admin** (`setConfig`, `installCA`/`uninstallCA`, `uninstall`, `loadConfig`/`reloadConfig`, `configFilePath`) ; `configureShell`/`unconfigureShell` et `setAutoStart` passent par `model` sans `admin` (donc `IntegrationSettingsView` n'en a pas besoin) :

- `GeneralSettingsView` — `@State maxSubsText`, `@State maxBackupsText` ; Picker exfil + 2 TextField `onSubmit`.
- `CertificateSettingsView` — lit `model.caTrusted`, boutons Install/Uninstall.
- `IntegrationSettingsView` — lit `model.shellConfigured` + `model.daemonAutoStart`/`appAutoStart` ; bouton Configure/Remove + 2 toggles (gère `.requiresApproval`/`.notFound` comme aujourd'hui).
- `AdvancedSettingsView` — lignes read-only `connection` + boutons Reveal/Reload.
- `UninstallSettingsView` — bouton destructif + `confirmationDialog` (keep/delete secrets) + `alert` « Almost done ».

L'affichage erreur/statut (`errorText`/`statusText`) devient **local à chaque section** (plus simple et isolé qu'un état partagé global).

## 5. Recâblage panneau / modèle

- `AppModel.Tab` : `case overview, logs, security, secrets, rules` (sans `.settings`). **Pas de migration** : `AppModel.swift:67-68` fait déjà `Tab.init(rawValue:)` + fallback `?? .overview`, donc une valeur persistée « settings » devenue inconnue retombe sur `.overview`.
- `BrokerPanelView.TabBar.items` : retrait de la ligne `.settings` (→ 5 items) ; switch de contenu sans `case .settings`.
- `AppDelegate.openSettings()` :
  ```swift
  @objc private func openSettings() {
      settingsWindowController?.show()
  }
  ```
  (le `settingsWindowController` est créé dans `applicationDidFinishLaunching`, injecté `admin`/`appModel` comme `panelController`.)
- L'item de menu « Settings… » (keyEquivalent `,`) du Lot 1 est inchangé ; seule l'action pointe désormais sur la fenêtre.

## 6. Décisions arrêtées

- **Titre fenêtre** : « Iris Settings ».
- **Mécanisme** : `NSWindow` custom + `NavigationSplitView` (tranché vs scene SwiftUI `Settings`, qui rend en onglets-en-haut et exige un sélecteur système variable pour l'ouverture depuis le menu AppKit).
- **Regroupement sidebar** : option B (4 sections + Uninstall), tranché vs miroir 1:1 des 7 sections.
- **`SettingsTab.swift` supprimé** (non conservé), son contenu étant intégralement migré.
- **Libellés ANGLAIS** (cohérent avec Lot 1 et l'IHM existante).

## 7. Vérification

Posture identique au Lot 1 (écart TDD assumé) : la cible Xcode `IrisApp` n'a **aucun harnais de tests UI** ; tester la structure d'une sidebar SwiftUI serait tautologique (anti Rule 9). La vérification est donc :

1. `xcodebuild -project IrisApp/IrisApp.xcodeproj -scheme IrisApp -configuration Debug build` puis `Release` → **BUILD SUCCEEDED**. (Le scheme `IrisApp` n'est PAS dans le workspace SPM `iris` → toujours `-project`.)
2. `swift build` + `swift test` (IrisAppCore/IrisKit) restent verts — confirme que le retrait de `Tab.settings` ne casse aucun test (aucun ne référence `.settings` ni `Tab.allCases`).
3. `swift-format lint --strict` sur les fichiers touchés (rappel : `.swift-format` exige 1 argument/ligne sur les initialiseurs multi-lignes).
4. CI macos-15 (build-test + xcode-build) verte.
5. **Smoke visuel** (checklist de la PR) :
   - « Settings… » (clic-droit icône) ouvre la fenêtre **Iris Settings** au premier plan ;
   - sidebar = General · Certificate · Integration · Advanced · ─ · Uninstall ; chaque section affiche son contenu et reste **fonctionnelle** (changer une policy, installer/désinstaller CA, toggler un auto-start, Reveal/Reload) ;
   - le panneau monitoring n'a plus que **5 onglets** (Overview/Logs/Security/Secrets/Rules) ;
   - fermer la fenêtre la masque ; « Settings… » la ré-ouvre ;
   - aucune régression sur le panneau (clic gauche, Pause daemon, Freeze Logs).
