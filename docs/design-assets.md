# Ressources graphiques — IRIS

> Inventaire et préparation des assets visuels du projet IRIS, du logo aux screenshots GitHub.
> Cibles : `Iris.app` (Phase 6), distribution `.pkg` signé + notarisé (Phase 9-10), release publique (Phase 10).
> Sources : [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [Apple Design Resources](https://developer.apple.com/design/resources/), [SF Symbols](https://developer.apple.com/sf-symbols/).

---

## 1. Outils à installer

À faire maintenant, en parallèle des phases en cours :

- [ ] **Xcode 26+** (inclut Icon Composer pour macOS Tahoe Liquid Glass icons)
- [ ] **SF Symbols app** — https://developer.apple.com/sf-symbols/ (browser + export d'icônes système)
- [ ] **productbuild** — fourni avec les Xcode Command Line Tools, aucun install (assemblage `.pkg` signé, déjà utilisé par `packaging/build-pkg.sh`)
- [ ] **vhs** ou **asciinema** — pour capturer le flow CLI en SVG/GIF animé (Phase 10 README)

Outils de design optionnels (selon préférence) : Figma, Sketch, Affinity Designer, ou tout outil capable d'exporter du SVG / PNG haute résolution.

---

## 2. Icône `Iris.app` — incontournable

### Approche moderne (recommandée) : Icon Composer

Depuis Xcode 26 et macOS 26 Tahoe, Apple a unifié la création d'icônes multi-plateformes autour d'un **fichier `.icon` unique** (multi-couches, vectoriel) que Icon Composer convertit automatiquement en :

| Cible | Généré |
|---|---|
| macOS 26+ | Variantes **light / dark / tinted / clear** (Liquid Glass) |
| macOS 13–15 (notre minimum Ventura → Sequoia) | Fallback `.icns` classique |
| Toutes tailles | 16, 32, 64, 128, 256, 512, 1024 px en @1x et @2x |

→ **Une seule source, génération auto**. Vs l'ancien flow où il fallait fournir 14 PNG individuels dans un asset catalog.

### Spécifications de design

- **Forme** : carré arrondi (rayon géré automatiquement par macOS), pas de bord opaque
- **Marge interne** : ~10% de safe area (le système crop légèrement)
- **Style** : profondeur, dégradés subtils, matériau qui répond à Liquid Glass (verre, transparence)
- **Lisibilité** : doit fonctionner à 16×16 (Finder list view) ET 1024×1024 (Dock zoomé). Pas de détails fins.

### Si on reste sur l'ancien système

Asset catalog Xcode avec set complet de PNG, ou `.icns` compilé via `iconutil` à partir d'un dossier `.iconset`. Plus simple à outsourcer mais rendu daté sur macOS 26.

---

## 3. Icône menu bar `NSStatusItem` — critique pour IRIS

Format **complètement différent** de l'icône app : on travaille en template image monochrome.

### Spécifications techniques

| Critère | Valeur |
|---|---|
| Format | PDF vectoriel (préféré) ou PNG monochrome avec alpha mask |
| Taille | 18×18 points (donc PDF vectoriel ou 18/36/54 PNG @1x/@2x/@3x) |
| Couleur | Noir + transparence (macOS tinte automatiquement selon clair/sombre/accent) |
| API | `NSImage.isTemplate = true`, ou `NSImage(systemSymbolName:)` pour SF Symbols |

### États visuels IRIS

La menu bar est la surface principale de **status awareness**. Il faut prévoir plusieurs glyphes :

| État daemon | Glyphe / variation | Quand |
|---|---|---|
| Actif (up, idle) | Icône principale neutre | Daemon en fonctionnement nominal |
| Substitution en cours | Pulse / point vert | Pendant ≥1 substitution |
| Pause | Variante désaturée + overlay "‖" | `daemon.pause` actif |
| Alerte exfil bloquée | Variante rouge ou badge | Une règle `exfil_blocked` a fired |
| Erreur (down) | Variante grisée + ⚠ | Daemon non joignable |

→ À arbitrer en **Phase 6** (menu bar app).

### MVP recommandé : SF Symbols

Pour Phase 6, **commencer avec un SF Symbol** plutôt que produire une icône custom dès le départ :

```swift
// État nominal
statusItem.button?.image = NSImage(systemSymbolName: "lock.shield",
                                    accessibilityDescription: "IRIS active")

// État pause
statusItem.button?.image = NSImage(systemSymbolName: "pause.circle",
                                    accessibilityDescription: "IRIS paused")

// État alerte
statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.shield",
                                    accessibilityDescription: "IRIS alert")
```

Candidats SF Symbols pertinents pour IRIS : `lock.shield`, `key.viewfinder`, `eye`, `shield.lefthalf.filled`, `network.badge.shield.half.filled`.

Custom à produire seulement en **Phase 10 hardening**, et seulement si jugé worth-it pour le branding.

---

## 4. Assets de l'installeur `.pkg` (Phase 9-10, optionnels)

La distribution est un `.pkg` **guidé** (assistant pas-à-pas), pas un `.dmg` drag-and-drop. Les assets DMG classiques (image de fond avec flèche, volume icon, alias `/Applications`) **ne s'appliquent pas**. Un `.pkg` se personnalise via un fichier **Distribution XML** passé à `productbuild --distribution` :

| Asset | Spec | Utilité |
|---|---|---|
| `welcome` | RTF / HTML | Écran d'accueil de l'assistant |
| `readme` | RTF / HTML | Notes (prérequis, étape « Install CA », setup shell) |
| `license` | RTF / texte | Licence (cf `LICENSE`) |
| `conclusion` | RTF / HTML | Écran final (« Iris installé — ouvrez l'app pour installer la CA ») |
| `background` | PNG (@1x + @2x) | Image de fond de l'assistant (panneau gauche) |

État actuel : `packaging/build-pkg.sh` utilise `productbuild --component` (paquet simple, aucun écran custom). Pour ajouter ces écrans, passer à `productbuild --distribution <Distribution.xml>` (Phase 9-10).

Sans ces assets : l'installeur reste fonctionnel mais minimal. Avec : parcours soigné + l'étape « Install CA » expliquée en clair.

---

## 5. Assets README & GitHub Release

Pas un livrable technique mais ça compte pour l'adoption.

| Asset | Spec | Outil suggéré |
|---|---|---|
| Bannière README | 1280×640 px (ratio 2:1) | Figma / Affinity Designer |
| Screenshots menu bar app | Captures système macOS, 3-5 vues | `cmd-shift-4` puis `cmd-shift-5` pour menu bar item |
| Asciicast / GIF du flow CLI | SVG ou MP4, ≤2 MB | `vhs` (https://github.com/charmbracelet/vhs) ou `asciinema` |
| Logo SVG | Vectoriel, fond transparent | Réutilisable doc / pres / site web |
| OG image (social sharing) | 1200×630 px | Réutiliser bannière README adaptée |

---

## 6. Identité visuelle — décision préalable

Avant de produire le moindre asset final, **arbitrer la direction visuelle**. À écrire dans `docs/brand.md` ou directement intégrer au SPECS.

### Le piège du nom

**Nom = IRIS** → la métaphore œil / iris est évidente mais aussi **clichée pour un produit de "surveillance/sécurité"**. Risque de paraître Big Brother alors que le produit est censé *protéger* l'utilisateur en interceptant ses propres flux.

### Pistes alternatives

- **Géométrique abstrait** : anneau concentrique, diaphragme stylisé, évoquant un iris sans en être un littéralement
- **Métaphore réseau** : nœud, broker, gateway — IRIS est un proxy de credentials, pas un surveillant
- **Métaphore interception/diffraction** : prisme, lentille, motif de diffraction
- **Pur typographique** : monogramme "I" / glyph géométrique

### Palette suggérée (sobre, sécurité)

| Rôle | Couleur |
|---|---|
| Primary | Bleu profond (cohérence "système", sérieux) |
| Accent actif | Vert mat (substitution réussie, daemon up) |
| Accent alerte | Rouge / orange (exfil bloquée, erreur) |
| Neutres | Gris froids (UI menu, secondaires) |

### Ton

- Pro, technique, sobre
- **Pas** de mascotte / illustration cartoon
- **Pas** de motifs "hacker" (terminal vert sur noir, cadenas avec chaînes)
- Référence visuelles à viser : 1Password, Tailscale, Little Snitch, LuLu, BlockBlock — outils sécurité macOS qui ont une identité crédible

---

## 7. Récapitulatif par phase

| Asset | Phase | Bloquant ? | Effort estimé |
|---|---|:---:|---|
| SF Symbols app installée | Maintenant | Non | 10 min |
| Icon Composer (via Xcode 26+) | Maintenant | Non | déjà installé si Xcode 26+ |
| Direction visuelle décidée | Avant Phase 6 | ⚠ | 1h réflexion |
| SF Symbol menu bar (placeholder) + états | Phase 6 | ✅ | 30 min |
| Icône app `Iris.app` finale | Phase 9-10 | Cosmétique | 4-8h ou outsourcing |
| Écrans installeur `.pkg` (welcome/readme/background) | Phase 9-10 | Cosmétique | 2-3h |
| Icône menu bar custom | Phase 10 | Non (SF Symbol acceptable) | 2-4h |
| Bannière README | Phase 10 | Non | 1-2h |
| Screenshots app | Phase 10 | Oui pour release | 1h |
| Asciicast / GIF CLI | Phase 10 | Non | 1-2h |

→ **Aucun asset graphique n'est bloquant pour Phase 9** (notarisation). Tu peux notariser et tester l'install avec un placeholder. Mais **distribuer publiquement** avec un icon générique = mauvaise première impression.

---

## 8. Checklist d'exécution

### Maintenant (préparation)

- [ ] Vérifier que Xcode 26+ est installé (`xcodebuild -version`)
- [ ] Installer SF Symbols app
- [ ] Créer le dossier `assets/` à la racine du repo (versionné, contient les sources de design)

### Avant Phase 6

- [ ] Décision direction visuelle (œil / abstrait / géométrique / typo) — courte note dans `docs/brand.md`
- [ ] Palette retenue (3-5 couleurs avec codes hex)
- [ ] Sélection SF Symbols candidats pour les 5 états menu bar

### Phase 6 (menu bar app)

- [ ] Implémentation `NSStatusItem` avec 5 états SF Symbols + accessibility labels
- [ ] Test : changement d'état visible et correctement tinté en clair/sombre

### Phase 9-10 (distribution)

- [ ] Icône `Iris.app` finale via Icon Composer (fichier `.icon` source dans `assets/`)
- [ ] Écrans installeur `.pkg` (welcome / readme / license / conclusion / background) via Distribution XML
- [ ] (optionnel) Passer `packaging/build-pkg.sh` de `--component` à `--distribution`
- [ ] Bannière README + intégration `README.md`
- [ ] 3-5 screenshots de l'app en action
- [ ] Asciicast / GIF du flow CLI

---

## 9. Organisation du dossier `assets/`

Suggestion de structure à versionner dans le repo (sources de design, pas les artefacts générés) :

```
assets/
├── app-icon/
│   └── Iris.icon              # source Icon Composer
├── menu-bar/
│   ├── states.md              # mapping état → SF Symbol / asset
│   └── custom/                # si custom plus tard
│       ├── active.pdf
│       ├── paused.pdf
│       ├── alert.pdf
│       └── error.pdf
├── installer/
│   ├── background.png         # fond assistant .pkg (@1x + @2x)
│   ├── welcome.html           # écrans Distribution XML (productbuild --distribution)
│   └── conclusion.html
├── readme/
│   ├── banner.png             # 1280×640
│   ├── screenshots/
│   └── cli-flow.svg           # asciicast / vhs output
└── brand/
    ├── logo.svg
    ├── palette.md             # couleurs hex + usage
    └── typography.md          # si police custom
```

À exclure de ce qui est versionné : artefacts générés (`.icns` compilés, PNG exportés depuis le source), à régénérer via build script.

---

## 10. Liens utiles

- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon) (legacy)
- [SF Symbols](https://developer.apple.com/sf-symbols/)
- [Apple Design Resources](https://developer.apple.com/design/resources/) — templates Sketch / Figma officiels
- [Liquid Glass design overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- [Human Interface Guidelines — App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Human Interface Guidelines — The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [Distribution XML reference (productbuild)](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html)
- [vhs (Charm)](https://github.com/charmbracelet/vhs) — terminal recordings reproductibles
