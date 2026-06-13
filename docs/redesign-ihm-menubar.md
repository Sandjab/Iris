# Redesign IHM — app menu-bar (diagnostic & recommandations)

> **Statut : proposition.** Rien n'est implémenté. Ce document consolide un diagnostic
> d'interaction/IA et une critique visuelle de l'IHM existante, avec des recommandations
> priorisées et des **décisions encore ouvertes** (cf. §7). Ce n'est pas une spec figée :
> `SPECS.md` reste la source de vérité technique.
>
> Date : 2026-06-13.

---

## 1. Périmètre

- **Dans le périmètre** : l'app menu-bar `Iris.app` — comportement de l'icône `NSStatusItem`
  et fenêtre du broker (`BrokerPanelView`, 6 onglets).
- **Hors périmètre** : le daemon, la CLI, le manuel web / GitHub Pages.
- **Nature de la fenêtre** : on conserve le **`NSPanel` non-activant** actuel. « Fenêtre normale »
  s'entend ici au sens *vraie fenêtre déplaçable/redimensionnable vs popover ancré* — pas au sens
  `NSWindow` activante standard. Le caractère non-activant (ne vole pas le focus clavier du
  terminal) est un choix délibéré qu'on ne remet pas en cause.

## 2. État actuel (factuel)

| Élément | Comportement | Référence code |
|---|---|---|
| Icône — clic gauche | `toggle()` du panneau | `IrisApp/IrisApp/AppDelegate.swift:132-146` |
| Icône — clic droit / ctrl+clic | Menu à 1 item « Quit Iris » | `AppDelegate.swift:138-158` |
| Status item | `sendAction(on: [.leftMouseUp, .rightMouseUp])` | `AppDelegate.swift:58-65` |
| Panneau | `NSPanel` non-activant, titré/redimensionnable, min 420×480, frame sauvegardée | `MainPanelController.swift:46-71` |
| Contenu | Dashboard à 6 onglets via `TabBar` custom | `BrokerPanelView.swift:8-32`, `:138-180` |
| Onglets | Overview · Logs · Security · Secrets · Rules · Settings | `BrokerPanelView.swift:22-27`, `:148-155` |
| Sélection d'onglet | `@Binding model.selectedTab` (pilotable de l'extérieur) | `BrokerPanelView.swift:16`, `:139` |

Captures de référence : voir §8 (clair + sombre, par onglet).

## 3. Méthode & limites

- Critique conduite avec le skill `impeccable:critique`. **Impeccable est orienté web** : sa
  détection « AI slop » (gradient text, glassmorphism, glow…) est **largement N/A** ici, car l'IHM
  est bâtie sur des composants système (`NSMenu`, `NSPanel`, SF Symbols template, `Color.accentColor`).
  C'est un point fort, pas un manque : le natif est anti-slop par construction. On ne garde que les
  dimensions transposables (hiérarchie, IA, affordance, microcopy, états, émotion).
- **Grille « good Mac citizen »** : skill communautaire `petekp/macos-app-design` (vraiment
  SwiftUI/AppKit, traite l'archétype menu-bar). Récupéré localement dans
  `.claude/design-refs/petekp-macos-app-design/` (gitignoré — pas de licence, non redistribuable).
- **Conventions Apple** : à valider via `sosumi` (HIG macOS), conformément à `CLAUDE.md §4`.
- **État capturé** : daemon Up, 234 requêtes / 52 substitutions, **trousseau vide** → plusieurs
  onglets en *empty state* (utile pour les juger ; pas de contenu riche). Aucun secret de test n'a
  été ajouté au trousseau.
- **Le visuel des 6 onglets a été observé sur captures réelles** (clair + sombre).

---

## 4. Recommandations — Interaction & architecture d'information

### R1 — « Settings » est un libellé surchargé sur deux niveaux
- **Constat** : le menu envisagé aurait un item « Settings » ouvrant la fenêtre. Or la fenêtre est
  un **dashboard à 6 onglets** dont un onglet « Settings ». Deux « Settings » désignant des choses
  différentes.
- **Pourquoi** : collision de vocabulaire — l'utilisateur ne sait plus ce que « Settings » ouvre.
- **Proposition** : item menu = **« Ouvrir Iris »** / **« Tableau de bord… »** (ouvre le dashboard) ;
  réserver **« Réglages… »** (⌘, , ellipsis = convention Apple) pour cibler directement l'onglet
  `.settings`. Techniquement trivial : `model.selectedTab = .settings` puis `show()`
  (binding confirmé `BrokerPanelView.swift:16`).

### R2 — Modèle d'interaction de l'icône + découvrabilité de « Quitter »
- **Constat** : aujourd'hui « Quitter » n'est accessible que par clic droit / ctrl+clic
  (`AppDelegate.swift:138-142`). Rien ne l'annonce. Le souhait initial (tout passer derrière un menu)
  réglerait la découvrabilité mais **sacrifierait l'accès direct au contenu** (clic gauche = 1 geste).
- **Deux directions** :
  - **Option A (recommandée)** : clic gauche **inchangé** (ouvre le dashboard) ; on **enrichit le menu
    secondary-click** : « Réglages… » (⌘,) + séparateur + « Quitter ». En complément, rendre
    Quitter/Réglages **découvrables dans le dashboard** (ex. menu `•••` ou gear dans le `HeaderBar`),
    pour que « Quitter » ne dépende plus du seul clic droit. Le clic droit reste un raccourci.
  - **Option B** : clic gauche et droit ouvrent le **même menu** (« Ouvrir Iris » + « Réglages… » +
    « Quitter »). Plus simple à expliquer, mais +1 geste pour accéder au dashboard à chaque fois.
- **Décision ouverte** : A vs B (cf. §7).

### R3 — Navigation : tab bar à 6 items tassée → quelle forme idiomatique ?
- **Constat** : 6 onglets custom horizontaux (icône + `caption2`) dans une largeur min de 420 px
  (`BrokerPanelView.swift:31`, `:148-155`). Tassé, cibles petites, et réimplémentation manuelle d'un
  composant (`Button(.plain)`) au lieu d'un composant système.
- **Pourquoi** : charge cognitive (6 destinations d'égal poids à l'ouverture) ; une tab bar plate
  prétend que Overview (lecture) = Secrets (action) = Settings (config rare).
- **Nuance HIG** (Sidebars) — la sidebar « façon Réglages Système » n'est *pas* le défaut pour un
  espace contraint :
  > « A sidebar requires a large amount of vertical and horizontal space. When space is limited […]
  > a more compact control such as a tab bar may provide a better navigation experience. »
  Deux pièges à adopter la forme System Settings telle quelle : (1) **changement d'archétype**
  (utility menu-bar compacte → app de réglages fenêtrée large) qui **aggrave V1** ; (2) **faux-ami** :
  Réglages Système ne contient que de la config, alors qu'IRIS mêle monitoring live (Overview, Logs,
  alertes) et config (Rules, Settings).
- **Trois options** (API : `NavigationSplitView`, macOS 13+) :
  - **(a) Tab bar, mieux faite** — compacter, regrouper les sections froides, composant standard.
    *Préférée par la HIG pour cet espace.* Reste fidèle à « apparaître / s'effacer ».
  - **(b) Full sidebar façon System Settings** — idiomatique et scalable, **mais impose une fenêtre
    nettement plus large** et abandonne la compacité. À réserver à une vision « console de supervision ».
  - **(c) Scinder les deux natures** — panneau **compact** pour le vivant (état + events + alertes +
    secrets) **et** une vraie fenêtre **« Réglages… » (⌘,)** au format sidebar/System Settings pour la
    config (Rules, politique Security, CA, Terminal, Launch at login, Uninstall). Convention macOS
    (fenêtre principale ≠ fenêtre Settings) ; réconcilie R1 + R3 + le faux-ami.
- **Décision ouverte** : (a) / (b) / (c) — cf. §7. Source : [HIG — Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars).

### R4 — Redondance de l'état dans le HeaderBar
- **Constat** : l'état est signalé 3 fois — forme de l'icône menu-bar, `StatusDot` (couleur seule,
  `BrokerPanelView.swift:98-112`), `StatusLabel` (texte adjacent).
- **Pourquoi** : le dot coloré duplique le label voisin ; un dot *color-only* est faible pour le
  daltonisme (le texte sauve le sens, mais le dot n'ajoute rien).
- **Proposition** : supprimer le dot, ou lui donner une forme/symbole. `« Up • 3h12m »` se suffit.

---

## 5. Recommandations — Visuel

### V1 — Vide vertical massif / fenêtre surdimensionnée *(le plus frappant)*
- **Constat** : Overview, Security, Secrets, Rules occupent 25-40 % de la hauteur ; le reste est vide
  (fenêtre 954×657, contenu Overview ~360 px). « No secrets. » flotte au centre d'un océan blanc.
- **Pourquoi** : une utility menu-bar devrait être compacte (« apparaître, s'effacer ») ; un panneau
  à moitié vide paraît inachevé. La largeur 954 px est aussi excessive pour des `host:port` courts.
- **Proposition** : taille **adaptative au contenu** (les onglets-liste comme Logs justifient la
  hauteur ; les onglets-résumé non), ou fenêtre par défaut nettement plus petite + scroll.

### V2 — Doublon du bouton « Pause » (Logs)
- **Constat** : le header a un bouton « Pause » (daemon) ; l'onglet Logs ajoute un **second** « Pause »
  dans sa barre d'outils. Deux « Pause » visibles simultanément.
- **Pourquoi** : ambiguïté (pause le daemon ? le flux de logs ?) + bruit.
- **Proposition** : distinguer — daemon = « Pause », flux logs = « Geler »/« Figer ».

### V3 — Redondance `github.com   github.com:443` (Overview + Logs)
- **Constat** : chaque ligne montre le host puis host:port ; la 1ʳᵉ colonne est incluse dans la 2ᵉ.
- **Proposition** : une seule colonne `host:port`, ou host en gras + `:443` atténué.

### V4 — Listes denses sans rythme (Logs)
- **Constat** : colonne entière de pilules `passThrough` identiques, lignes serrées sans séparateur
  ni regroupement temporel.
- **Proposition** : zebra subtil, regroupement par heure, ou masquer le badge quand il est uniforme.

### V5 — Empty states qui ne guident pas
- **Secrets** : « No secrets. » centré = anti-pattern (« nothing here » sans action). Le bouton
  « + Add » existe en haut mais l'empty state n'y renvoie pas. → « Aucun secret. Ajoutez-en un pour
  substituer vos credentials. » + CTA central.
- **Security** : « 0 unread » alors qu'une alerte HIGH est affichée juste en dessous → contradiction
  apparente (compteur non-lu vs liste affichée).

### V6 — Hiérarchie des métriques (Overview)
- **Constat** : `234 Requests / 52 Substituted / 1 Blocked / 1 Errors` traités à égalité de poids
  (« hero metric layout »).
- **Pourquoi** : pour un broker de sécurité, « Blocked » et « Errors » (incidents) méritent plus de
  poids que « Requests » (volume brut).
- **Proposition** : hiérarchiser visuellement les incidents au-dessus du volume.

### Microcopy
- `block_and_notify` exposé en snake_case dans le dropdown Settings → humaniser (« Bloquer et notifier »).
- Vocabulaire d'état hétérogène : header « Up », icône « active » (`AppDelegate.swift:170-183`),
  Settings parle de « services ». Harmoniser.

### Mode sombre — RAS
Composants système → dérivation sémantique propre. `Trusted` vert / `Not configured` orange /
`HIGH` rouge restent lisibles sur fond foncé. Pas de problème de contraste.

---

## 6. Priorisation suggérée

- **Quick wins (peu de risque, fort gain de propreté)** : V2 (doublon Pause), V3 (host redondant),
  R1 (libellé), microcopy snake_case, R4 (dot redondant).
- **Structurels (à cadrer avant de coder)** : R2 (modèle d'interaction icône), R3 (tab bar → sidebar),
  V1 (taille adaptative), V5/V6 (empty states & hiérarchie incidents).

> Les « commandes » impeccable (`/distill`, `/clarify`, `/onboard`…) génèrent du **code web** :
> à traiter ici comme des **directions conceptuelles à appliquer à la main en SwiftUI**, pas des
> transformations à lancer telles quelles.

## 7. Décisions ouvertes

1. **R2 — Option A ou B** pour le modèle d'interaction de l'icône (reco : A).
2. **Périmètre de la passe** : se limiter à l'interaction de l'icône, ou traiter l'IHM large
   (les 6 onglets) ? Si large → cadrer via brainstorming avant de coder.
3. **V1 — fenêtre** : taille adaptative au contenu vs taille fixe réduite par défaut.
4. **R3 — forme de navigation** : (a) tab bar améliorée / (b) full sidebar façon System Settings /
   (c) panneau compact + fenêtre Réglages dédiée. Décision liée au positionnement produit
   (utility ponctuelle vs console de supervision). Maquette comparative : `playgrounds/`.

## 8. Snapshots de référence

Captures réelles de l'app prod (daemon Up, trousseau vide), clair + sombre.

| Onglet | Clair | Sombre |
|---|---|---|
| Overview | [light-overview.png](../assets/snapshots/light-overview.png) | [dark-overview.png](../assets/snapshots/dark-overview.png) |
| Logs | [light-logs.png](../assets/snapshots/light-logs.png) | [dark-logs.png](../assets/snapshots/dark-logs.png) |
| Security | [light-security.png](../assets/snapshots/light-security.png) | [dark-security.png](../assets/snapshots/dark-security.png) |
| Secrets | [light-secrets.png](../assets/snapshots/light-secrets.png) | [dark-secrets.png](../assets/snapshots/dark-secrets.png) |
| Rules | [light-rules.png](../assets/snapshots/light-rules.png) | [dark-rules.png](../assets/snapshots/dark-rules.png) |
| Settings | [light-settings.png](../assets/snapshots/light-settings.png) | [dark-settings.png](../assets/snapshots/dark-settings.png) |

## 9. Références

- Code : `AppDelegate.swift`, `MainPanelController.swift`, `BrokerPanelView.swift` (lignes en §2/§4/§5).
- Grille « good Mac citizen » : `.claude/design-refs/petekp-macos-app-design/` (local, gitignoré).
- HIG macOS : via `sosumi` (cf. `CLAUDE.md §4`).
