# Redesign IHM — Lot 3 : refonte du contenu du panneau (design)

> **Statut : design validé, prêt à planifier.** Décisions arbitrées en brainstorming (maquettes
> comparatives). Ce document résout les décisions ouvertes §7 du diagnostic
> [`redesign-ihm-menubar.md`](redesign-ihm-menubar.md) pour le périmètre Lot 3 et spécifie
> l'implémentation. `SPECS.md` reste la source de vérité technique.
>
> Date : 2026-06-14. Branche : `feat/ihm-lot-3-panneau-compact`.

---

## 1. Périmètre

Refonte **large** du contenu du panneau `BrokerPanelView` (5 onglets, post-Lots 1 & 2). Items
traités : **V1, V6, R4, V5, V4, microcopy**. **V3 retiré** (sans objet, cf. §6).

**Hors périmètre** : daemon, CLI, fenêtre Réglages dédiée (Lot 2), manuel web. Le `NSPanel`
non-activant est **conservé** (choix délibéré, cf. diagnostic §1).

**Langue de l'IHM : anglais.** L'app est en anglais (preuves : `SecretsTab` « No secrets. » / « Add »,
`OverviewTab` « Since daemon start » / « Recent events », `SecurityTab` « Mark all read »). Toute
nouvelle chaîne user-facing est donc en **anglais** pour rester homogène (Rule 11). Une localisation
française serait un chantier séparé, hors Lot 3. Les libellés ci-dessous sont en anglais.

## 2. Décisions arbitrées

| Item | Décision | Note |
|---|---|---|
| **V1** (taille) | **C — densifier** : garder ~480×600, combler le vide par du contenu utile, ne pas rétrécir. | Assume un panneau « console de monitoring » plutôt qu'utility minimale. |
| **V6** (hiérarchie Overview) | **B — 4 cartes pondérées** : Requests/Substituted en gris/petit, Blocked/Errors en gras coloré. | Hiérarchie par taille + couleur, peu disruptif. |
| **R4** (dot redondant) | **Symbole à forme** (pas suppression pure) : ● up / ❚❚ paused / ▲ down. | Affordance glanceable conservée + lisible sans couleur (daltonisme). |
| Sparkline | **Conservée** dans le scope. | Alimentée par le buffer d'events en mémoire ; libellée « recent ». |

## 3. Design par composant

### 3.1 HeaderBar — R4 + microcopy (`BrokerPanelView.swift:76-135`)

- Remplacer `StatusDot` (un `Circle().fill(color)` *color-only*, `:97-111`) par un **SF Symbol dont
  la forme encode l'état**, pas seulement la couleur :
  - `.up` non pausé → `circle.fill` (ou `checkmark.circle.fill`), vert ;
  - `.up` pausé → `pause.circle.fill`, orange ;
  - `.down` → `exclamationmark.triangle.fill`, rouge ;
  - `.connecting` → `circle.dotted`, gris.
- `StatusLabel` inchangé sur le fond (« Up · 3h 12m » / « Paused · … » / « Daemon down » /
  « Connecting… »). Le symbole précède le label.
- **Vérifier** l'existence + la disponibilité macOS 13 des symboles via `sosumi` avant usage
  (CLAUDE.md §4). Pas d'invention de nom de symbole.

### 3.2 OverviewTab — V1=C + V6=B + sparkline (`OverviewTab.swift`)

Structure cible de haut en bas, dans le `ScrollView` existant :

1. **Compteurs pondérés** (remplace `countersSection`, `:19-30`) — rangée de 4 :
   - `Requests`, `Substituted` : style **volume** (valeur `.title3`/atténuée `.secondary`, label petit).
   - `Blocked`, `Errors` : style **incident** (valeur `.title` bold + couleur rouge/orange, label `.medium`).
   - Source inchangée : `DaemonStats` (`reqTotal/subTotal/exfilBlockedTotal/errorsTotal`).
2. **Sparkline « Activity (recent) »** — nouveau bloc :
   - Série dérivée du **buffer `model.events`** (ring cap 1000, chaque `Event` horodaté), bucketée
     sur N intervalles (ex. 12 buckets sur la fenêtre couverte). C'est un **transform déterministe
     pur** → vit dans `IrisAppCore` (fonction testable), **pas** dans la vue (CLAUDE.md / Rule 5).
   - Rendu minimal natif (barres ou `Path`), pas de dépendance graphique tierce.
   - **Libellé honnête** : « recent » — couvre la fenêtre d'events en mémoire, **pas** la durée de
     vie du daemon (les compteurs §1 le font déjà). Si le buffer est vide → masquer le bloc.
3. **Recent events** (`recentSection`, `:44-55`) — comble le bas. Augmenter `prefix(5)` pour
   remplir la hauteur (ex. `prefix(8-10)`). `EventRow` compact **inchangé** (time · badge · host · path).

La fenêtre garde son défaut actuel (`MainPanelController.swift:47` : 480×600 ; `contentMinSize`
420×480). **Aucune logique de redimensionnement auto** (on a écarté l'option adaptative).

### 3.3 LogsTab — V4 rythme (`LogsTab.swift`)

La barre de filtres (`:21-46`, Freeze inclus) est **inchangée**. Refonte de la **ligne** : aujourd'hui
Logs réutilise `EventRow` (partagé avec Overview). On introduit une **ligne dédiée Logs** (vue
séparée, ex. `LogEventRow`) — Overview garde sa ligne compacte :

- **Barre d'accent couleur** en tête de ligne (filet vertical 2-3 px) encodant le `kind` :
  vert `substituted` / gris `passThrough`/`noMatch` / rouge `exfilBlocked` / orange `error`.
  Remplace la pilule `passThrough` répétée et criarde (le « bruit » du diagnostic V4).
- **Lignes enrichies** avec les champs **déjà présents dans `Event` mais jamais affichés**
  (`Event.swift` : `method`, `statusCode`, `durationMs`) : `time · method · host · path · status · durée`.
  `statusCode` coloré (2xx/3xx vert, 4xx/5xx rouge/orange) ; champs optionnels (`nil`) omis proprement.
- **Pas de zebra** : la liste préprend les events en live → un zebra basé sur l'index re-colorie
  toutes les lignes à chaque arrivée (scintillement). La barre d'accent + l'enrichissement portent
  le rythme. Pas non plus de regroupement temporel (complexité non justifiée).

### 3.4 SecretsTab + RulesTab — V5 empty states guidés

- **Secrets** (`SecretsTab.swift:52-55`) : remplacer le « No secrets. » centré muet par un empty
  state **guidé** : icône (`key`) + titre « No secrets yet » + sous-texte « Add one to substitute
  your credentials in allowed traffic. » + **CTA central** « Add secret » déclenchant
  `route = .form(.add)` (même action que le bouton « Add » du haut).
- **Rules** (`RulesTab.swift:54-57`) : même patron pour « No rules. » (CTA pointant le champ d'ajout
  / focus). Cohérence visuelle avec Secrets.

### 3.5 SecurityTab — V5 cohérence (`SecurityTab.swift`)

- Entête : remplacer le seul « N unread » (`:13-15`), qui paraît contradictoire avec des alertes
  listées en dessous, par « **N alerts · M unread** » (total + non-lues). « Mark all read »
  inchangé.
- Empty state « No alerts. » (`:30-33`) → patron guidé cohérent avec Secrets/Rules
  (« No alerts. » + courte phrase rassurante, ex. « Exfiltration attempts will appear here. »).

### 3.6 Microcopy

- **Vocabulaire d'état unifié** : le tooltip de l'icône (`AppDelegate.swift:200` : `"active"`/
  `"paused"`) s'aligne sur le lexique du header (`"Up"`/`"Paused"`). Un seul vocabulaire dans toute
  l'IHM.
- **`block_and_notify`** : humaniser les `rawValue` snake_case du Picker de politique d'exfiltration
  (`SettingsSections.swift:84`, **fenêtre Réglages** ; enum `ExfilAttemptPolicy` : `block_only` /
  `block_and_notify` / `block_notify_pause`) → libellés « Block only » / « Block & notify » /
  « Block, notify & pause » (mapping d'affichage côté app, **sans** toucher le `rawValue` transmis au
  daemon ni l'usage `rawValue` de la CLI). *Léger débordement hors panneau, assumé car microcopy trivial.*

## 4. Tests (intention, pas seulement comportement — Rule 9)

- **Sparkline bucketing** (`IrisAppCore`) : transform pur → tests unitaires déterministes
  (buffer vide → série vide/masquée ; répartition correcte sur N buckets ; monotonie des timestamps).
- **Pondération compteurs / entête Security** : la logique « M non lues » s'appuie sur
  `unreadAlertCount` existant — test que l'entête reflète bien total vs non-lues.
- **Redaction maintenue** : V4 enrichit les lignes Logs ; vérifier qu'aucune valeur de secret ne
  fuit (les `substitutedSecrets` sont des **noms**, jamais des valeurs — invariant SPECS §6.1 / CLAUDE
  §6.1). Ajouter/garder un test de redaction sur le rendu de ligne enrichie.
- **Empty states** : pas de logique métier → couverts par le smoke visuel, pas de test unitaire forcé.

## 5. Contraintes d'implémentation (rappels durables)

- Cible Xcode `IrisApp` = `PBXFileSystemSynchronizedRootGroup` → ajouter un `.swift` (ex. nouvelle
  `LogEventRow`, helper sparkline si vue) **n'exige aucune édition `.pbxproj`**.
- **Aucune vue IrisApp n'est `@MainActor`** (target pas en strict-concurrency, contrairement aux
  cibles SPM). La logique testable (sparkline) va dans `IrisAppCore`, qui **est** en strict-concurrency.
- Oracle de compilation = `swift build` / `swift test` + `xcodebuild -project IrisApp/IrisApp.xcodeproj
  -scheme IrisApp` ; **SourceKit retarde** sur le compilateur (faux « Cannot find type »).
- `swift-format` avant commit (1 argument par ligne sur les constructions multi-args).
- Pas de `print()`, pas de force-unwrap, `Sendable` où requis.

## 6. Non-goals / décisions explicites

- **V3 retiré** : la duplication `host github.com:443` décrite au diagnostic **n'existe pas** dans le
  code actuel — `Event` n'a pas de champ `port` (`Event.swift:4-15`) et `EventRow` rend `host` + `path`,
  pas `host:port`. Rien à corriger.
- **Option adaptative (V1-B) écartée** : saut au changement d'onglet + conflit avec le resize manuel
  et l'autosave de frame.
- **NSPanel non-activant conservé** : ne vole pas le focus clavier du terminal.

## 7. Smoke testing (pré-rempli pour la PR)

- [ ] Overview rempli ~480×600, plus de vide vertical massif (trousseau vide ET avec events).
- [ ] Compteurs : Blocked/Errors visuellement dominants ; Requests/Substituted atténués.
- [ ] Sparkline rendue quand events présents, **masquée** quand buffer vide ; libellée « recent ».
- [ ] HeaderBar : symbole d'état change de **forme** entre up / paused / down (pas juste la couleur).
- [ ] Logs : barre d'accent par kind, lignes method/status/durée, zebra ; « pass » non criard.
- [ ] Secrets vide → empty state guidé + CTA central lance le formulaire d'ajout.
- [ ] Rules vide → empty state guidé cohérent.
- [ ] Security : entête « N alertes · M non lues » ; empty state « Aucune alerte » guidé.
- [ ] Tooltip icône et header utilisent le même vocabulaire d'état.
- [ ] Picker politique : « Bloquer et notifier » (plus de snake_case).
- [ ] Mode sombre : tous les écrans relus, contrastes OK.
- [ ] Aucune valeur de secret visible dans Logs/Overview enrichis.
