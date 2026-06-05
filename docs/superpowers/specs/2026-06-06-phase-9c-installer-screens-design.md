# Phase 9c — Installeur `.pkg` guidé (écrans + marque)

> Faire passer la distribution d'un `.pkg` nu (`productbuild --component`, aucun
> écran) à un **assistant pas-à-pas** : écrans welcome / readme / license /
> conclusion + image de fond de marque, **bilingues (en/fr)**, via
> `productbuild --distribution`. Restructure `packaging/build-pkg.sh` autour d'un
> composant `pkgbuild` + un produit `productbuild --distribution`, puis re-notarise.
> **Packaging-only : zéro `.swift`, zéro `.pbxproj`.**
> Sources : `docs/design-assets.md` §4 (assets installeur), SPECS §18
> (build pipeline / postinstall / uninstall). Objectif G6 (« single signed and
> notarized `.pkg` »), volet présentation.

## 1. Objectif et portée

L'installeur actuel fonctionne mais n'affiche **aucun écran** : `productbuild
--component "$APP" /Applications` produit un paquet simple. Cette phase ajoute le
parcours guidé (accueil, prérequis, licence, conclusion) et l'identité visuelle
de marque, sans toucher au code applicatif.

**Dans le périmètre :**
- 4 écrans Distribution XML — `welcome`, `readme`, `license`, `conclusion` — en
  **HTML** (sauf la licence en texte), **localisés en/fr** via dossiers `*.lproj`.
- Image de fond de l'assistant — `background.png` (@1x) + `background@2x.png`,
  direction **D2/doré** (cf §2.3), **rendue une fois et commitée**.
- Restructuration `packaging/build-pkg.sh` : `pkgbuild` (composant) +
  `productbuild --distribution … --resources … --sign --timestamp`.
- `Distribution.xml` commité (synthétisé puis enrichi).
- Ré-exécution `packaging/notarize.sh` (profil `iris-notary`, inchangé) sur le
  nouveau `.pkg` → staple + `spctl --assess`.

**Hors périmètre (frontières explicites) :**
- ❌ Toute modification de code Swift / de la cible Xcode IrisApp. La phase
  n'exerce **pas** le CI (build du `.pkg` = local, certs requis) ; `swift test`
  reste à 455.
- ❌ Auto-start / `--first-launch` → **Phase 7**. Le `postinstall` reste **inerte**
  (création du dossier `Application Support` seulement) ; la conclusion invite donc
  à **ouvrir l'app manuellement**.
- ❌ Étapes 1-6 de `build-pkg.sh` (build irisd, archive/export, embed, signature
  inner-first, vérif codesign) — **inchangées**.
- ❌ Génération de la CA / install trust store / setup shell — déjà livrés
  (Phase 8a + onglet Settings 6.3b + `iris ca install`). 9c ne fait qu'y **renvoyer**
  par du texte.
- ❌ Icône d'app finale (`.icns` / Icon Composer) — cosmétique distincte, non
  bloquante (design-assets §7).

## 2. Décisions de design

### 2.1 — Pipeline : composant `pkgbuild` + produit `productbuild --distribution`

`productbuild --distribution` **n'accepte pas** la forme `--component <app>
/Applications` (les deux usages sont exclusifs — confirmé `man productbuild` :
`--component` est « Valid only if --distribution is not specified »). Il faut donc :

1. `pkgbuild --component "$APP" --install-location /Applications
   --scripts packaging/scripts --identifier io.iris.app --version "$VERSION"
   build/component/Iris-component.pkg` → **composant non signé**.
2. `productbuild --distribution packaging/installer/Distribution.xml
   --package-path build/component --resources packaging/installer/resources
   --sign "$INSTALLER_IDENTITY" --timestamp build/Iris.pkg` → **produit signé**.

C'est `productbuild --sign` qui signe le produit final (Developer ID Installer) ;
le composant `pkgbuild` reste non signé (pratique standard pour un composant
incorporé dans un produit `--distribution`).

Rejeté : **garder `--component`** → impossible d'avoir des écrans (c'est tout
l'objet de la phase).

### 2.2 — Localisation bilingue via `*.lproj`

`man productbuild` (`--resources`) : le dossier de ressources « can contain
unlocalized resources (such as image files) and/or standard lproj directories
… containing localized resources ». On range donc les écrans dans
`resources/en.lproj/` et `resources/fr.lproj/` ; Installer.app sélectionne selon
la langue système. **Primaire = anglais** (cohérent avec l'app, le README, SPECS,
LICENSE — toute la surface produit est en anglais) ; **fr** en traduction.

Les images de fond (`background.png`, `background@2x.png`) sont **non localisées**
→ à la racine de `resources/`.

`<title>` du Distribution = `Iris` (nom de produit, neutre) — on ne localise pas
les chaînes de niveau Distribution (over-engineering) ; tout le contenu lisible
qui change selon la langue vit dans les écrans HTML localisés.

### 2.3 — Marque : direction D2/doré (validée en brainstorm visuel)

Image de fond : silhouette de **Mercure** (le messager — métaphore du broker
intermédiaire, fournie par l'utilisateur) en bleu nuit `#0E2A47`, wordmark
« Iris », filet d'accent **doré `#C9912E`**, sur fond gris-bleu pâle `#F6F8FC`.
Composition **cantonnée à gauche / bas-gauche** : le volet de droite de l'Installer
porte son propre texte + le bouton « Continuer » → le fond doit rester discret
derrière. `alignment`/`scaling` exacts **réglés au smoke**.

`background.png` / `background@2x.png` sont **rendus une fois et commités** (pas de
génération au build → pas de dépendance ImageMagick dans la release). La silhouette
dérive de l'image source fournie (recolorée navy). Méthode de rendu (SVG rasterisé
ou composition) = détail du plan d'implémentation ; l'asset livré est le PNG.

### 2.4 — `Distribution.xml` commité, synthétisé puis enrichi

Base générée via `productbuild --synthesize --package build/component/Iris-component.pkg
Distribution.xml` (garantit des `pkg-ref`/`choices-outline` corrects), puis enrichie
à la main des éléments présentation : `<title>`, `<welcome file="welcome.html"/>`,
`<readme file="readme.html"/>`, `<license file="license.txt"/>`,
`<conclusion file="conclusion.html"/>`, `<background file="background.png"
alignment="bottomleft" scaling="proportional"/>` (valeurs d'alignement à confirmer
au smoke). Le `pkg-ref` `id`/`version` doit **rester aligné** sur `--identifier`/
`--version` du `pkgbuild` (cf §2.6 gotcha).

### 2.5 — Scripts d'install → `pkgbuild --scripts`

`preinstall`/`postinstall` (inchangés, inertes) migrent de `productbuild --scripts`
vers `pkgbuild --scripts packaging/scripts` : avec `--distribution`, les scripts
appartiennent au **composant**. (Le `--scripts` de `productbuild` ne sert qu'aux
`system.run()` du Distribution — hors de notre cas.)

### 2.6 — Licence : source unique

`packaging/build-pkg.sh` **copie le `LICENSE` racine** (MIT) dans
`resources/en.lproj/license.txt` **et** `resources/fr.lproj/license.txt` au build
(le texte légal MIT n'est pas traduit — standard). Source unique = le `LICENSE`
racine ; les `license.txt` générés sont **gitignorés**.

## 3. Arborescence cible

```
packaging/
├── build-pkg.sh              # restructuré (étapes 7-8)
├── notarize.sh               # inchangé, ré-exécuté sur le nouveau .pkg
├── exportOptions.plist       # inchangé
├── io.iris.daemon.plist      # inchangé
├── scripts/                  # inchangé ; déplacé vers pkgbuild --scripts
│   ├── preinstall
│   └── postinstall
└── installer/                # NOUVEAU
    ├── Distribution.xml       # commité (synthétisé + enrichi)
    └── resources/             # → --resources
        ├── background.png      # D2/doré, commité, non localisé
        ├── background@2x.png
        ├── en.lproj/  welcome.html  readme.html  conclusion.html  [license.txt généré]
        └── fr.lproj/  welcome.html  readme.html  conclusion.html  [license.txt généré]
```

`.gitignore` : ajouter `packaging/installer/resources/**/license.txt` (artefact de
build copié depuis `LICENSE`).

## 4. Restructuration `build-pkg.sh`

Étapes **0-6 inchangées**. Remplacement de l'étape 7 (`productbuild --component`) :

```
# Variables ajoutées
VERSION="${IRIS_PKG_VERSION:-0.1.0}"
COMPONENT_DIR="$BUILD/component"
COMPONENT_PKG="$COMPONENT_DIR/Iris-component.pkg"
RESOURCES="packaging/installer/resources"

# 7a. Licence : source unique
cp LICENSE "$RESOURCES/en.lproj/license.txt"
cp LICENSE "$RESOURCES/fr.lproj/license.txt"

# 7b. Composant (non signé)
mkdir -p "$COMPONENT_DIR"
pkgbuild --component "$APP" --install-location /Applications \
  --scripts packaging/scripts \
  --identifier io.iris.app --version "$VERSION" \
  "$COMPONENT_PKG"

# 7c. Produit guidé signé
productbuild --distribution packaging/installer/Distribution.xml \
  --package-path "$COMPONENT_DIR" \
  --resources "$RESOURCES" \
  --sign "$INSTALLER_IDENTITY" --timestamp \
  "$PKG"

# 8. Vérif (inchangée)
pkgutil --check-signature "$PKG"
```

## 5. Contenu des écrans (substance)

Anglais primaire ; fr = traduction fidèle. Ton sobre, factuel (cf README).

- **welcome** — ce qu'est Iris (broker de credentials local pour outils CLI/agents) ;
  ce que l'installeur fait (copie `Iris.app` dans `/Applications`, crée
  `~/Library/Application Support/iris`). Annonce que la **configuration** (CA + shell)
  se fait **au premier lancement de l'app**.
- **readme** — prérequis : **macOS 13+**, **droits admin** (install + ajout CA au
  trust store). Note clé : interception **CLI-only** — les apps GUI lancées depuis
  Finder/Dock/Spotlight ne sont **pas** interceptées (par design, G8). Aperçu du
  setup shell (configuré automatiquement par l'app) : `HTTPS_PROXY=http://127.0.0.1:8888`,
  `NODE_EXTRA_CA_CERTS=~/Library/Application Support/iris/ca.pem`.
- **license** — `LICENSE` MIT (texte brut, identique en/fr).
- **conclusion** — « Iris est installé. » Étapes suivantes : ouvrir **Iris** depuis
  la barre de menus → installer la CA dans le trust store (prompt admin) et configurer
  le shell ; alternative CLI `iris ca install`. Rappel : **ouvrir un nouveau terminal**
  pour charger les variables d'environnement. (Pas d'auto-start : Phase 7.)

## 6. Notarisation

`packaging/notarize.sh` **inchangé** (profil notarytool `iris-notary`, Team ID dérivé
du trousseau). Ré-exécuté sur le nouveau `build/Iris.pkg` → `notarytool submit --wait`
→ `stapler staple` → `spctl --assess --type install` doit rendre
`accepted source=Notarized Developer ID`. (Stapler sur le `.pkg` suffit — acquis 9b.)

## 7. Vérification & smoke

**Zéro `.swift`/`.pbxproj`** → CI (build-test + xcode-build macos-15) **inchangé**,
reste vert (455 tests). L'oracle de cette phase est **manuel, au poste** :

1. `IRIS_TEAM_ID=… ./packaging/build-pkg.sh` → `build/Iris.pkg` produit, signé,
   `pkgutil --check-signature` OK.
2. **Smoke GUI** : ouvrir `build/Iris.pkg` → dérouler **welcome → readme → license
   → conclusion**, **image de fond visible** et lisible (texte de l'Installer non
   masqué), licence affichée. Vérifier le rendu **fr** sur un système en français
   (ou via `defaults`/langue système).
3. Installer → `Iris.app` présent dans `/Applications` ; dossier
   `~/Library/Application Support/iris` créé (postinstall).
4. `./packaging/notarize.sh build/Iris.pkg` → `Accepted` + staple + `spctl` notarized.

## 8. Risques / gotchas durables

- **Placement du fond** : `<background>` s'affiche derrière le contenu de l'Installer.
  Risque de collision wordmark/texte → composition à gauche/bas-gauche ;
  `alignment`/`scaling` à régler au smoke (fallback : emblème seul, plus discret).
- **Résolution lproj** : les écrans sont référencés par **basename** dans le
  Distribution ; productbuild les résout par langue dans chaque `*.lproj` de
  `--resources`. Garder `Distribution.xml` **hors** de `resources/` (il est passé via
  `--distribution`, pas comme ressource).
- **Sync version** : `pkg-ref` (`id`/`version`) du Distribution doit matcher
  `--identifier io.iris.app` / `--version "$VERSION"` du `pkgbuild`. Drift = produit
  incohérent. Une seule source de vérité (`IRIS_PKG_VERSION`), répétée littéralement
  dans le XML (documenté).
- **Bundle fantôme** : `build/export/Iris.app` partage `io.iris.app` avec le build
  Debug DerivedData ; purger au besoin (`lsregister -u` + `rm -rf`).
- **Re-sign daemon** : ne **pas** rebuilder/re-signer `irisd` juste pour ce smoke
  (casse un secret 8b lié à la signature) ; 9c ne touche pas au daemon.
