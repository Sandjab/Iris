# Design — Fenêtre déplaçable pour l'IHM menu-bar

> Date : 2026-06-06
> Cible : `Iris.app` (target `IrisApp`)
> Statut : design validé, prêt pour plan d'implémentation

## 1. Problème

L'IHM de l'app menu-bar est aujourd'hui un `NSPopover` (480×600) ancré au bouton du
`NSStatusItem` (`AppDelegate.swift:94-103`). Deux frictions pour l'utilisateur :

- **Trop petite / trop éloignée** : le popover est figé en haut de l'écran, sous l'icône,
  loin de la zone de travail, taille fixe.
- **S'auto-ferme** : comportement `.applicationDefined` + global-monitor outside-click
  (`AppDelegate.swift:166-178`) → tout clic hors de l'app la ferme. Pratique pour un coup
  d'œil, frustrant pour éditer secrets/règles.

## 2. Décisions (validées avec l'utilisateur)

1. **Remplacer** le popover par une **vraie fenêtre déplaçable + redimensionnable** (un seul
   chemin, pas de coexistence popover+fenêtre).
2. **Placement** : centrée à l'écran au 1er lancement, puis **mémorise position + taille**
   entre ouvertures et entre redémarrages.
3. **Focus** : **panneau flottant non-activant** — flotte au-dessus des autres fenêtres, ne
   vole PAS le focus clavier de l'app de premier plan (terminal/éditeur). Les champs texte
   prennent le focus seulement au clic.

## 3. Approche retenue : `NSPanel` non-activant (AppKit, fait main)

Le contenu SwiftUI (`PopoverView`) est déjà une vue autonome. « Passer à une fenêtre » =
changer l'**hôte** (de `NSPopover` vers `NSPanel`), pas le contenu.

### Alternatives écartées

- **Scène SwiftUI `Window`/`WindowGroup`** (macOS 13) : aucun accès à `styleMask` / `level` /
  `hidesOnDeactivate` → impossible de configurer un panneau flottant **non-activant** dans une
  app `LSUIElement`. Ne sait pas exprimer le « ne vole pas le focus ». Rejeté.
- **`MenuBarExtra(.window)`** : fenêtre ancrée à l'icône, non déplaçable — c'est le popover
  déguisé. Ne répond pas à la demande. Rejeté.

## 4. Conception détaillée

### 4.1 Nouveau fichier `IrisApp/IrisApp/MainPanelController.swift`

Contrôleur AppKit mince qui possède le `NSPanel` + son `NSHostingController`.

- API publique : `show()` (montre + amène devant), `toggle()` (masque si visible, sinon
  `show()`), `isVisible`.
- **Pas de seam/protocole de test** : c'est de la glue de présentation pure, rien à mocker
  (cohérent avec le fait qu'aucune vue IrisApp n'est testable headless ; le gate CI
  xcodebuild couvre la compilation).
- Création **paresseuse** au premier `show()`/`toggle()`, puis retenue pour la durée du
  process.
- Ajouter ce `.swift` n'exige **aucune** édition de `project.pbxproj` (la cible `IrisApp`
  utilise un `PBXFileSystemSynchronizedRootGroup` — découverte de fichiers automatique).

### 4.2 Configuration du `NSPanel`

| Propriété | Valeur | Raison |
|---|---|---|
| `styleMask` | `[.titled, .closable, .resizable, .nonactivatingPanel]` | barre de titre = glisser-déposer + bouton fermer gratuits ; non-activant = ne vole pas le focus |
| `title` | « Iris » | — |
| `isFloatingPanel` | `true` | comportement panneau utilitaire |
| `level` | `.floating` | flotte au-dessus du terminal/éditeur |
| `hidesOnDeactivate` | `false` | **override obligatoire** : le défaut `NSPanel` est `true` → sinon le panneau disparaît dès qu'on revient au terminal |
| `becomesKeyOnlyIfNeeded` | `true` | panneau non-activant : ne prend le focus clavier que quand un champ texte (hit view `needsPanelToBecomeKey == true`) est cliqué ; boutons/onglets n'attrapent pas le focus |
| `isReleasedWhenClosed` | `false` | fermer = masquer, on réouvre au clic icône (instance retenue) |
| `contentMinSize` | `420×480` | borne basse de redimensionnement |
| contentRect initial | `480×600` | parité avec le popover actuel |

**Persistance** : `setFrameAutosaveName("IrisBrokerPanel")` persiste position + taille
(AppKit, gratuit). Au tout premier lancement, `setFrameUsingName(...)` renvoie `false`
(aucune frame sauvée) → appeler `panel.center()`.

**Doc Apple vérifiée** (`NSPanel.becomesKeyOnlyIfNeeded`) : *« If the panel is a
non-activating panel, then it becomes key only if the hit view returns true from
needsPanelToBecomeKey. This way, a non-activating panel can control whether it takes keyboard
focus. »* → un champ texte cliqué prend le focus clavier sans activer l'app.

### 4.3 Modifications `AppDelegate.swift`

Supprimer :
- `private var popover: NSPopover?` et `private var popoverMonitor: Any?`
- le bloc de création du `NSPopover` (`:94-103`)
- `togglePopover()`, `openPopover()`, `closePopover()` (`:149-179`) et le global-monitor
  outside-click (une vraie fenêtre ne s'auto-ferme pas)

Remplacer par :
- `private let panelController = MainPanelController(...)` (injecté avec `admin` + `appModel`)
- clic gauche (`handleClick`, cas non-secondaire) → `panelController.toggle()`
- clic sur notification (closure passée à `NotificationCoordinator`) → `panelController.show()`

Inchangés (restent sur le bouton status) : menu Quit (ctrl/clic droit, `showQuitMenu`), badge
`unreadAlertCount` (`updateBadge`), pulse d'icône (`pulseIcon`), protection multi-instance.

### 4.4 Modification `PopoverView.swift`

- Ligne 31 : `.frame(width: 480, height: 600)` →
  `.frame(minWidth: 420, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)` pour que
  le contenu suive le redimensionnement de la fenêtre.
- **Rename `PopoverView` → `BrokerPanelView`** (décidé) : « Popover » devient trompeur. Renommer
  le struct + le fichier `PopoverView.swift` → `BrokerPanelView.swift`. Sites à mettre à jour
  (vérifiés par grep) : (a) le `rootView` du `NSHostingController` — qui migre dans
  `MainPanelController` (§4.1), pas dans `AppDelegate` ; (b) le commentaire `AppDelegate.swift:10`
  qui mentionne « `PopoverView` reuses it » à propos de `defaultAdminSocketPath()` →
  reformuler (le réutilisateur devient `MainPanelController`). Aucune autre référence.

### 4.5 Politique d'activation

L'app **reste** `.accessory` (`LSUIElement`, `IrisAppApp.swift:8`). Un panneau non-activant
peut devenir key pour l'édition de texte **sans** changer la policy → aucun juggling
d'activation (l'avantage décisif vs une fenêtre d'app standard, qui imposerait de basculer
`.regular`/`.accessory`). La scène `Settings { EmptyView() }` reste inchangée.

### 4.6 Comportement du clic icône

**Toggle** : panneau visible → masquer (`orderOut`) ; masqué → `show()` (restaure la frame
sauvée ou centre, `orderFront`). Conserve la mémoire musculaire du popover. Ajustable si la
sémantique « toujours amener devant » est préférée à l'usage.

## 5. Risque & vérification

**Risque unique** : édition des champs texte (Add secret / Add rule) dans un panneau
non-activant via SwiftUI/`NSHostingController`. La doc confirme le mécanisme
(`needsPanelToBecomeKey`), mais le pont SwiftUI mérite une vérification en réel → item de smoke.

## 6. Definition of Done

- [ ] `swift build` + `swift test` verts (IrisAppCore intact — aucune logique métier touchée).
- [ ] **Gate CI `xcodebuild` macOS-15 vert** = oracle pour les changements IrisApp (le build
      local, toolchain plus récente, ne fait pas foi).
- [ ] `swift-format` clean.

### Checklist smoke (poste physique requis)

- [ ] Clic icône → fenêtre **centrée à l'écran** au tout premier lancement.
- [ ] Déplacer + redimensionner la fenêtre → position & taille **persistent** après fermeture
      puis réouverture.
- [ ] Position & taille persistent aussi après **quit + relaunch** de l'app.
- [ ] La fenêtre **flotte au-dessus** du terminal/éditeur.
- [ ] On peut **taper dans le terminal** pendant que la fenêtre est visible (pas de vol de
      focus).
- [ ] **Édition d'un champ** (Add secret / Add rule) : curseur + saisie OK dans le panneau.
- [ ] Badge `unreadAlertCount`, pulse d'icône, menu Quit (ctrl/clic droit) : inchangés.
- [ ] Clic notification (alerte) → ouvre/amène la fenêtre devant.

## 7. Hors périmètre

- Pas de refonte de la disposition interne des onglets (contenu `PopoverView` réutilisé tel
  quel).
- Pas de `collectionBehavior` multi-Spaces / over-fullscreen (follow-up éventuel si besoin).
- Pas de toggle « épingler / niveau flottant » configurable (le niveau `.floating` est fixé).
- Pas de nouveau réglage persistant dans `config.json` (la frame est gérée par AppKit via
  `setFrameAutosaveName`, stockée dans les `UserDefaults` standard de l'app).
