# Spec — Lot 1 : interaction de l'icône menu-bar

> Statut : **validé en brainstorming**, prêt pour le plan d'implémentation.
> Date : 2026-06-13.
> Contexte global : premier lot de la passe de redesign IHM — voir
> [`docs/redesign-ihm-menubar.md`](../../redesign-ihm-menubar.md) (R1, R2, V2).

## 1. Objectif

Améliorer l'interaction de l'icône `NSStatusItem` et lever une ambiguïté de libellé, sans
toucher à la **forme de navigation** du panneau (réservée au Lot 2). Couvre :

- **R2 (Option A, validée)** : clic gauche inchangé ; menu secondary-click enrichi.
- **R1** : un item « Settings… » qui ouvre le panneau directement sur l'onglet Settings.
- **V2** : relabel du bouton « Pause » de l'onglet Logs (qui gèle l'affichage, pas le daemon).

## 2. Hors périmètre (explicitement)

- **Découvrabilité de « Quit » dans la surface** (bouton ⚙/••• dans le HeaderBar) → **Lot 2**
  (le HeaderBar sera refait avec la refonte navigation ; l'ajouter ici serait jetable).
- **Forme de navigation** (options a/b/c) → Lot 2.
- **V3/V4** (design des lignes d'event) → lot « contenu » séparé.
- Libellés : **on reste en anglais** (cohérence avec toute l'UI existante ; pas de francisation).

## 3. Design détaillé

### 3.1 Détection du clic
`AppDelegate.handleClick(_:)` (`AppDelegate.swift:132-146`) garde sa structure actuelle :
- clic gauche → `panelController?.toggle()` (**inchangé**) ;
- secondary-click = `rightMouseUp` **ou** `leftMouseUp` + `.control` (déjà géré `:138-140`)
  → ouvre le menu.

`showQuitMenu(from:)` (`:148-158`) est renommé `showStatusMenu(from:)` et construit le menu ci-dessous.

### 3.2 Le menu secondary-click
Ordre conventionnel macOS :

```
About Iris
Settings…            ⌘,
─────────────
Quit Iris            ⌘Q
```

- Chaque item a `target = self` et un `#selector` dédié.
- Les `keyEquivalent` (« , » et « q ») sont posés par convention ; dans un menu de status item
  ils n'agissent que menu ouvert (pas globalement) — connu et accepté, cosmétique.

### 3.3 Action « About Iris »
Panneau About **standard** : `NSApp.orderFrontStandardAboutPanel(nil)`. Il lit
`CFBundleName` / `CFBundleShortVersionString` / `NSHumanReadableCopyright` depuis `Info.plist`.
Comme l'app est `LSUIElement` non-activante, appeler `NSApp.activate(ignoringOtherApps: true)`
**juste avant** pour que le panneau passe au premier plan.
- *À vérifier à l'implémentation* : présence des clés `Info.plist` ci-dessus (sinon le panneau
  affiche des valeurs vides) ; comportement réel d'activation (smoke).

### 3.4 Action « Settings… »
Nouvelle méthode (p. ex. `openSettings`) :
```
appModel.selectedTab = .settings
panelController?.show()
```
Le binding `selectedTab` existe (`BrokerPanelView.swift:16`, `TabBar.swift:139`). Si le panneau
est déjà ouvert sur un autre onglet, il bascule sur Settings.
- *Note Lot 2* : quand la fenêtre Réglages dédiée de l'option (c) existera, « Settings… » sera
  rebranché vers elle.

### 3.5 Relabel V2
`LogsTab.swift:42` : `Toggle("Pause", isOn: pauseBinding)` → `Toggle("Freeze", isOn: pauseBinding)`.
**Aucune logique modifiée** (toujours `streamPaused` / `setStreamPaused`). Lève l'ambiguïté avec le
bouton « Pause » du HeaderBar (qui, lui, pause le daemon).

## 4. Fichiers touchés

| Fichier | Changement |
|---|---|
| `IrisApp/IrisApp/AppDelegate.swift` | `showQuitMenu`→`showStatusMenu` ; 3 items + 2 nouveaux selectors (`openSettings`, `showAbout`) |
| `IrisApp/IrisApp/LogsTab.swift` | libellé `Pause`→`Freeze` (ligne 42) |
| `IrisApp/IrisApp/Info.plist` *(à vérifier)* | clés About si absentes |

Pas de changement de modèle, d'IPC, ni de logique daemon.

## 5. Vérification

Pas de tests unitaires pertinents (vues `IrisApp`, aucun test UI dans le projet). Si la
construction du `NSMenu` est extraite dans une fonction pure (items → titres/selectors), un test
léger est possible ; sinon **smoke seul**.

Checklist de smoke (sur l'app buildée) :
- [ ] clic droit / ctrl+clic sur l'icône → menu `About Iris` · `Settings…` · ─ · `Quit Iris` ;
- [ ] clic gauche → ouvre/ferme le panneau (inchangé) ;
- [ ] « Settings… » → panneau ouvert **sur l'onglet Settings** (bascule si déjà ouvert ailleurs) ;
- [ ] « About Iris » → panneau About standard au premier plan (nom/version corrects) ;
- [ ] « Quit Iris » → quitte ;
- [ ] onglet Logs → le bouton est libellé **« Freeze »** et gèle toujours le flux ;
- [ ] aucune régression du Pause daemon (HeaderBar).

Build : `xcodebuild -scheme IrisApp -configuration Release build` (oracle final = CI macOS-15).

## 6. Risques / notes

- **About + LSUIElement** : sans `activate`, le panneau pourrait s'ouvrir derrière — d'où
  l'activation préalable. À confirmer au smoke.
- **`keyEquivalent` dans un status menu** : non-globaux, cosmétiques (idem actuel pour « q »).
- **Re-signature** : modifier l'app ne touche pas l'ACL des secrets (liée à `irisd`), et le
  trousseau est de toute façon vide — aucun risque ACL pour ce lot.
