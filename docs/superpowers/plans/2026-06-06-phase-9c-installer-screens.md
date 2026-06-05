# Phase 9c — Installeur `.pkg` guidé : Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transformer l'installeur `.pkg` d'IRIS d'un paquet nu en un assistant guidé bilingue (welcome / readme / license / conclusion + image de fond de marque), via `productbuild --distribution`.

**Architecture:** Packaging-only, zéro `.swift`/`.pbxproj`. On ajoute `packaging/installer/` (Distribution XML + ressources localisées `*.lproj` + image de fond commitée + script de génération), et on restructure `packaging/build-pkg.sh` pour bâtir un composant `pkgbuild` puis un produit signé `productbuild --distribution … --resources`. Notarisation (`notarize.sh`, profil `iris-notary`) inchangée, ré-exécutée sur le nouveau `.pkg`.

**Tech Stack:** `pkgbuild`, `productbuild` (Distribution XML), ImageMagick (`magick`, FreeType), `xmllint`, bash. Vérif structurelle headless (composant factice non signé) ; smoke final signé + notarisé = **manuel au poste** (certs Developer ID + GUI requis).

**Spec de référence :** `docs/superpowers/specs/2026-06-06-phase-9c-installer-screens-design.md`. Branche : `feat/phase-9c-installer-screens` (déjà créée, spec déjà commitée `a948dae`).

---

## File Structure

| Fichier | Responsabilité |
|---|---|
| `packaging/installer/src/mercury-silhouette.png` | **Créer.** Source de marque commitée (silhouette Mercure N&B, downscalée), pour régénérer le fond. |
| `packaging/installer/make-background.sh` | **Créer.** Régénère `background.png`/`@2x` depuis la source (masque → navy → composition). |
| `packaging/installer/resources/background.png` | **Créer (généré, commité).** Fond @1x 620×418. |
| `packaging/installer/resources/background@2x.png` | **Créer (généré, commité).** Fond @2x 1240×836. |
| `packaging/installer/resources/en.lproj/{welcome,readme,conclusion}.html` | **Créer.** Écrans anglais. |
| `packaging/installer/resources/fr.lproj/{welcome,readme,conclusion}.html` | **Créer.** Écrans français. |
| `packaging/installer/resources/{en,fr}.lproj/license.txt` | **Généré au build** (copie de `LICENSE`), **gitignoré**. |
| `packaging/installer/Distribution.xml` | **Créer.** Script GUI : title + écrans + fond + gate macOS 13 + pkg-ref. |
| `.gitignore` | **Modifier.** Ignorer les `license.txt` générés. |
| `packaging/build-pkg.sh` | **Modifier.** Étape 7 `--component` → licence + `pkgbuild` + `productbuild --distribution`. |

---

## Task 1: Asset de fond (silhouette source + script + PNG @1x/@2x)

**Files:**
- Create: `packaging/installer/src/mercury-silhouette.png`
- Create: `packaging/installer/make-background.sh`
- Create: `packaging/installer/resources/background.png`, `packaging/installer/resources/background@2x.png`

- [ ] **Step 1: Importer la silhouette source dans le repo (downscalée)**

La source fournie par l'utilisateur est une silhouette noire sur blanc 2048². On la downscale à 1024² et on la committe comme source de régénération (indépendante de `~/Downloads`).

```bash
mkdir -p packaging/installer/src packaging/installer/resources
magick "/Users/jean-paulgavini/Downloads/Gemini_Generated_Image_xbhouqxbhouqxbho (1).png" \
  -resize 1024x1024 packaging/installer/src/mercury-silhouette.png
sips -g pixelWidth -g pixelHeight packaging/installer/src/mercury-silhouette.png
```
Expected : `pixelWidth: 1024` / `pixelHeight: 1024`.

- [ ] **Step 2: Écrire `make-background.sh`**

Composition D2/doré : silhouette navy à gauche, wordmark « Iris », filet doré, tagline grise, sur fond gris-bleu `#F6F8FC`. Texte du fond en **anglais** (asset non localisé, produit EN-primaire). Coordonnées approximatives — affinables au smoke.

```bash
cat > packaging/installer/make-background.sh <<'SH'
#!/bin/bash
# Régénère background.png (@1x 620x418) + background@2x.png (@1x 1240x836)
# pour l'installeur guidé, depuis src/mercury-silhouette.png.
# Direction « D2/doré » : silhouette Mercure bleu nuit + filet doré sur gris-bleu.
set -euo pipefail
cd "$(dirname "$0")"
SRC="src/mercury-silhouette.png"
OUT="resources"
NAVY='#0E2A47'; GOLD='#C9912E'; BG='#F6F8FC'; GREY='#5B6B82'
FONT="/System/Library/Fonts/SFNS.ttf"

# 1. Silhouette N&B -> masque alpha -> remplissage navy (forme navy sur transparent)
magick "$SRC" \
  \( +clone -colorspace Gray -negate \) -alpha off -compose CopyOpacity -composite \
  -channel RGB -fill "$NAVY" -colorize 100 +channel /tmp/mercury-navy.png

# 2. Composition @2x (1240x836) : emblème gauche, reste libre pour le contenu Installer
magick -size 1240x836 "xc:$BG" \
  \( /tmp/mercury-navy.png -resize 480x480 \) -gravity NorthWest -geometry +110+150 -composite \
  -font "$FONT" -gravity NorthWest \
  -fill "$NAVY" -pointsize 100 -annotate +130+620 'Iris' \
  -fill "$GOLD" -draw 'rectangle 132,772 292,784' \
  -fill "$GREY" -pointsize 30 -annotate +132+800 'Local credential broker' \
  "$OUT/background@2x.png"

# 3. @1x = downscale propre du @2x
magick "$OUT/background@2x.png" -resize 620x418 "$OUT/background.png"
echo "OK -> $OUT/background.png + $OUT/background@2x.png"
SH
chmod +x packaging/installer/make-background.sh
```

- [ ] **Step 3: Générer le fond et vérifier dimensions + rendu**

```bash
./packaging/installer/make-background.sh
sips -g pixelWidth -g pixelHeight packaging/installer/resources/background.png
sips -g pixelWidth -g pixelHeight packaging/installer/resources/background@2x.png
```
Expected : `620×418` et `1240×836`. **Ouvrir les deux PNG** (Read/Preview) et vérifier visuellement : silhouette navy lisible à gauche, wordmark + filet doré, moitié droite vide. Ajuster les coordonnées du script si besoin et régénérer.

- [ ] **Step 4: Commit**

```bash
git add packaging/installer/src/mercury-silhouette.png packaging/installer/make-background.sh \
        packaging/installer/resources/background.png packaging/installer/resources/background@2x.png
git commit -m "feat(phase-9c): asset de fond installeur (D2/doré) + script de génération"
```

---

## Task 2: Écrans anglais (`en.lproj`)

**Files:**
- Create: `packaging/installer/resources/en.lproj/welcome.html`
- Create: `packaging/installer/resources/en.lproj/readme.html`
- Create: `packaging/installer/resources/en.lproj/conclusion.html`

- [ ] **Step 1: Écrire les 3 écrans HTML (anglais)**

```bash
mkdir -p packaging/installer/resources/en.lproj
```

`welcome.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Welcome to Iris</h2>
<p>Iris is a local credential broker for macOS. It lets command-line AI agents (such as Claude Code) use your real API keys without ever exposing them: Iris intercepts outbound HTTPS, substitutes placeholders like <code>{{kc:anthropic_api_key}}</code> with values pulled from your Keychain, and forwards the request upstream.</p>
<p>This installer will:</p>
<ul>
<li>Install <b>Iris.app</b> into <b>/Applications</b>.</li>
<li>Create the support folder <code>~/Library/Application Support/iris</code>.</li>
</ul>
<p>After installation, open Iris from the menu bar to finish setup (generate and trust the local CA, configure your shell).</p>
</body></html>
```

`readme.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Before you install</h2>
<h3>Requirements</h3>
<ul>
<li>macOS 13 (Ventura) or later.</li>
<li>Administrator rights — to install the app and to add Iris's local CA to the system trust store.</li>
</ul>
<h3>How interception works</h3>
<p>Iris only intercepts <b>processes launched from a shell</b> (terminals, scripts). The app sets up two environment variables for you on first launch:</p>
<ul>
<li><code>HTTPS_PROXY=http://127.0.0.1:8888</code></li>
<li><code>NODE_EXTRA_CA_CERTS=~/Library/Application Support/iris/ca.pem</code></li>
</ul>
<p>GUI apps launched from Finder, Dock or Spotlight (Safari, Mail, Slack…) are <b>not</b> intercepted — this is by design: the target use case is command-line agent tooling. The proxy listens only on <code>127.0.0.1</code>, so nothing is exposed to the network.</p>
</body></html>
```

`conclusion.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Iris is installed</h2>
<p>One more step to start protecting your credentials:</p>
<ol>
<li>Open <b>Iris</b> from the menu bar.</li>
<li>Let it generate the local CA and add it to your system trust store (you'll be prompted for your administrator password once).</li>
<li>It configures your shell automatically. Alternatively, run <code>iris ca install</code> in a terminal.</li>
</ol>
<p><b>Open a new terminal window</b> afterwards so the new environment variables are loaded.</p>
<p>Note: Iris does not start automatically after installation.</p>
</body></html>
```

- [ ] **Step 2: Vérifier que le HTML est bien formé**

```bash
for f in welcome readme conclusion; do
  xmllint --html --noout packaging/installer/resources/en.lproj/$f.html && echo "$f OK"
done
```
Expected : `welcome OK` / `readme OK` / `conclusion OK` (xmllint peut émettre des warnings HTML5 sur stderr ; seul un code retour non nul = échec).

- [ ] **Step 3: Commit**

```bash
git add packaging/installer/resources/en.lproj
git commit -m "feat(phase-9c): écrans installeur anglais (welcome/readme/conclusion)"
```

---

## Task 3: Écrans français (`fr.lproj`)

**Files:**
- Create: `packaging/installer/resources/fr.lproj/welcome.html`
- Create: `packaging/installer/resources/fr.lproj/readme.html`
- Create: `packaging/installer/resources/fr.lproj/conclusion.html`

- [ ] **Step 1: Écrire les 3 écrans HTML (français — traduction fidèle de Task 2)**

```bash
mkdir -p packaging/installer/resources/fr.lproj
```

`welcome.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Bienvenue dans Iris</h2>
<p>Iris est un broker de credentials local pour macOS. Il permet aux agents IA en ligne de commande (comme Claude Code) d'utiliser vos vraies clés d'API sans jamais les exposer : Iris intercepte le trafic HTTPS sortant, substitue des placeholders comme <code>{{kc:anthropic_api_key}}</code> par des valeurs tirées de votre trousseau, puis transmet la requête.</p>
<p>Cet installeur va :</p>
<ul>
<li>Installer <b>Iris.app</b> dans <b>/Applications</b>.</li>
<li>Créer le dossier de support <code>~/Library/Application Support/iris</code>.</li>
</ul>
<p>Après l'installation, ouvrez Iris depuis la barre de menus pour terminer la configuration (génération et confiance de la CA locale, configuration du shell).</p>
</body></html>
```

`readme.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Avant d'installer</h2>
<h3>Prérequis</h3>
<ul>
<li>macOS 13 (Ventura) ou ultérieur.</li>
<li>Droits administrateur — pour installer l'app et ajouter la CA locale d'Iris au trust store système.</li>
</ul>
<h3>Comment fonctionne l'interception</h3>
<p>Iris n'intercepte que les <b>processus lancés depuis un shell</b> (terminaux, scripts). L'app configure pour vous deux variables d'environnement au premier lancement :</p>
<ul>
<li><code>HTTPS_PROXY=http://127.0.0.1:8888</code></li>
<li><code>NODE_EXTRA_CA_CERTS=~/Library/Application Support/iris/ca.pem</code></li>
</ul>
<p>Les apps GUI lancées depuis le Finder, le Dock ou Spotlight (Safari, Mail, Slack…) ne sont <b>pas</b> interceptées — c'est volontaire : le cas d'usage cible est l'outillage CLI agentique. Le proxy n'écoute que sur <code>127.0.0.1</code>, rien n'est exposé au réseau.</p>
</body></html>
```

`conclusion.html` :
```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,Helvetica,sans-serif;color:#1b2a4a;font-size:13px;line-height:1.5">
<h2 style="color:#0E2A47">Iris est installé</h2>
<p>Une dernière étape pour commencer à protéger vos credentials :</p>
<ol>
<li>Ouvrez <b>Iris</b> depuis la barre de menus.</li>
<li>Laissez-le générer la CA locale et l'ajouter à votre trust store système (mot de passe administrateur demandé une fois).</li>
<li>Il configure votre shell automatiquement. Sinon, lancez <code>iris ca install</code> dans un terminal.</li>
</ol>
<p><b>Ouvrez une nouvelle fenêtre de terminal</b> ensuite pour charger les nouvelles variables d'environnement.</p>
<p>Note : Iris ne démarre pas automatiquement après l'installation.</p>
</body></html>
```

- [ ] **Step 2: Vérifier le HTML**

```bash
for f in welcome readme conclusion; do
  xmllint --html --noout packaging/installer/resources/fr.lproj/$f.html && echo "$f OK"
done
```
Expected : `welcome OK` / `readme OK` / `conclusion OK`.

- [ ] **Step 3: Commit**

```bash
git add packaging/installer/resources/fr.lproj
git commit -m "feat(phase-9c): écrans installeur français (welcome/readme/conclusion)"
```

---

## Task 4: Ignorer les `license.txt` générés

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Ajouter la règle d'ignore**

```bash
printf '\n# Phase 9c : licence copiée depuis LICENSE au build (source unique)\npackaging/installer/resources/*.lproj/license.txt\n' >> .gitignore
```

- [ ] **Step 2: Vérifier l'effet**

```bash
mkdir -p packaging/installer/resources/en.lproj
cp LICENSE packaging/installer/resources/en.lproj/license.txt
git check-ignore packaging/installer/resources/en.lproj/license.txt
rm packaging/installer/resources/en.lproj/license.txt
```
Expected : `git check-ignore` imprime le chemin (donc bien ignoré).

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore(phase-9c): gitignore les license.txt générés au build"
```

---

## Task 5: `Distribution.xml`

**Files:**
- Create: `packaging/installer/Distribution.xml`

Éléments/attributs confirmés sur la *Distribution XML Reference* d'Apple : `<title>`, `<welcome|readme|license|conclusion file= mime-type=>`, `<background file= alignment= scaling= mime-type=>` (alignment ∈ {center,left,right,top,bottom,topleft,topright,bottomleft,bottomright} ; scaling ∈ {tofit,none,proportional}), gate OS via `<volume-check><allowed-os-versions><os-version min=>`.

- [ ] **Step 1: Écrire `Distribution.xml`**

`pkg-ref` `id`/`version` alignés sur `pkgbuild --identifier io.iris.app --version 0.1.0` (Task 6). Le contenu textuel du `pkg-ref` final = le **nom de fichier** du composant (`Iris-component.pkg`), résolu via `--package-path`. Fond en `scaling="tofit"` (remplit la fenêtre, image authoring 620×418 ≈ ratio fenêtre, emblème à gauche).

```bash
cat > packaging/installer/Distribution.xml <<'XML'
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="1">
    <title>Iris</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <license file="license.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <background file="background.png" mime-type="image/png" alignment="left" scaling="tofit"/>
    <options customize="never" require-scripts="false"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="13.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="io.iris.app"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="io.iris.app" visible="false">
        <pkg-ref id="io.iris.app"/>
    </choice>
    <pkg-ref id="io.iris.app" version="0.1.0" onConclusion="none">Iris-component.pkg</pkg-ref>
</installer-gui-script>
XML
```

- [ ] **Step 2: Vérifier que le XML est bien formé**

```bash
xmllint --noout packaging/installer/Distribution.xml && echo "Distribution.xml OK"
```
Expected : `Distribution.xml OK`.

- [ ] **Step 3: Commit**

```bash
git add packaging/installer/Distribution.xml
git commit -m "feat(phase-9c): Distribution XML (écrans + fond + gate macOS 13)"
```

---

## Task 6: Restructurer `packaging/build-pkg.sh`

**Files:**
- Modify: `packaging/build-pkg.sh` (config + étapes 7-8 ; en-tête)

- [ ] **Step 1: Ajouter les variables de config**

Après la ligne `PKG="$BUILD/Iris.pkg"` (zone Config), insérer :

```bash
VERSION="${IRIS_PKG_VERSION:-0.1.0}"
COMPONENT_DIR="$BUILD/component"
COMPONENT_PKG="$COMPONENT_DIR/Iris-component.pkg"
RESOURCES="packaging/installer/resources"
DISTRIBUTION="packaging/installer/Distribution.xml"
```

- [ ] **Step 2: Remplacer l'étape 7 (et garder l'étape 8)**

Remplacer le bloc actuel :
```bash
# --- 7. PKG signé Developer ID Installer ----------------------------------
productbuild --component "$APP" /Applications \
  --scripts packaging/scripts \
  --sign "$INSTALLER_IDENTITY" --timestamp \
  "$PKG"
```
par :
```bash
# --- 7. PKG guidé signé Developer ID Installer ----------------------------
#   a. Licence : source unique -> copiée dans chaque lproj (gitignorée)
cp LICENSE "$RESOURCES/en.lproj/license.txt"
cp LICENSE "$RESOURCES/fr.lproj/license.txt"
#   b. Composant non signé (les scripts pre/postinstall s'attachent ICI)
mkdir -p "$COMPONENT_DIR"
pkgbuild --component "$APP" --install-location /Applications \
  --scripts packaging/scripts \
  --identifier io.iris.app --version "$VERSION" \
  "$COMPONENT_PKG"
#   c. Produit guidé (écrans + fond via Distribution XML) signé
productbuild --distribution "$DISTRIBUTION" \
  --package-path "$COMPONENT_DIR" \
  --resources "$RESOURCES" \
  --sign "$INSTALLER_IDENTITY" --timestamp \
  "$PKG"
```

- [ ] **Step 3: Mettre à jour le commentaire d'en-tête**

Remplacer la ligne d'en-tête (l.2) :
```bash
# IRIS build-pkg — Phase 9a : assemble Iris.app (irisd embarqué + plist), signe
```
par :
```bash
# IRIS build-pkg — assemble Iris.app (irisd embarqué + plist), signe inner-first,
# produit un .pkg GUIDÉ (écrans + fond, Phase 9c) signé Developer ID Installer.
```

- [ ] **Step 4: Vérifier la syntaxe bash**

```bash
bash -n packaging/build-pkg.sh && echo "syntaxe OK"
```
Expected : `syntaxe OK`.

- [ ] **Step 5: Commit**

```bash
git add packaging/build-pkg.sh
git commit -m "feat(phase-9c): build-pkg.sh -> pkgbuild composant + productbuild --distribution"
```

---

## Task 7: Vérification structurelle headless (composant factice, non signé)

But : prouver **sans certs** que `Distribution.xml` + `--resources` (lproj) + fond se câblent correctement, en bâtissant un produit `--distribution` **non signé** à partir d'un composant factice. Aucune modification commitée (vérification pure).

**Files:** aucun (artefacts temporaires sous `/tmp`).

- [ ] **Step 1: Bâtir un composant factice avec le même identifiant/version**

```bash
rm -rf /tmp/iris-9c && mkdir -p /tmp/iris-9c/approot/Iris.app/Contents /tmp/iris-9c/comp
printf '<?xml version="1.0"?><plist/>' > /tmp/iris-9c/approot/Iris.app/Contents/Info.plist
pkgbuild --root /tmp/iris-9c/approot --install-location /Applications \
  --identifier io.iris.app --version 0.1.0 \
  /tmp/iris-9c/comp/Iris-component.pkg
```
Expected : `pkgbuild: Wrote package to /tmp/iris-9c/comp/Iris-component.pkg`.

- [ ] **Step 2: Copier la licence dans les lproj puis bâtir le produit `--distribution` (non signé)**

```bash
cp LICENSE packaging/installer/resources/en.lproj/license.txt
cp LICENSE packaging/installer/resources/fr.lproj/license.txt
productbuild --distribution packaging/installer/Distribution.xml \
  --package-path /tmp/iris-9c/comp \
  --resources packaging/installer/resources \
  /tmp/iris-9c/Iris-unsigned.pkg
```
Expected : `productbuild: Wrote product to /tmp/iris-9c/Iris-unsigned.pkg` (aucune erreur de résolution de ressource).

- [ ] **Step 3: Étendre le produit et vérifier le câblage des écrans/fond/langues**

```bash
pkgutil --expand /tmp/iris-9c/Iris-unsigned.pkg /tmp/iris-9c/expanded
echo "--- Resources ---"; find /tmp/iris-9c/expanded/Resources -maxdepth 2 -type f | sort
test -f /tmp/iris-9c/expanded/Resources/en.lproj/welcome.html && \
test -f /tmp/iris-9c/expanded/Resources/fr.lproj/welcome.html && \
test -f /tmp/iris-9c/expanded/Resources/background.png && \
test -f /tmp/iris-9c/expanded/Distribution && echo "CÂBLAGE OK"
```
Expected : `CÂBLAGE OK`, et la liste montre `en.lproj/{welcome,readme,conclusion,license.txt}.html|txt`, idem `fr.lproj`, plus `background.png`/`background@2x.png`.

- [ ] **Step 4: Nettoyer les artefacts temporaires et les license.txt générés**

```bash
rm -rf /tmp/iris-9c
rm -f packaging/installer/resources/en.lproj/license.txt packaging/installer/resources/fr.lproj/license.txt
git status --short   # doit être propre (rien à committer)
```
Expected : working tree propre (les `license.txt` sont gitignorés ; on les retire pour ne pas polluer).

---

## Task 8: Smoke signé + notarisation — **MANUEL, AU POSTE** (certs + GUI requis)

⚠️ Non exécutable headless : nécessite les identités Developer ID, `xcodebuild` (archive ~10 min) et l'interaction GUI. À dérouler par l'utilisateur au poste.

- [ ] **Step 1: Build complet signé**

```bash
export IRIS_TEAM_ID="<Team ID Apple>"
./packaging/build-pkg.sh
pkgutil --check-signature build/Iris.pkg
```
Expected : `build/Iris.pkg` produit ; signature `Developer ID Installer` valide.

- [ ] **Step 2: Smoke GUI — dérouler l'assistant**

```bash
open build/Iris.pkg
```
Vérifier : écran **Welcome** → **Read Me** → **License** (MIT) → **Conclusion** ; **image de fond visible** et lisible (texte de l'Installer non masqué par l'emblème). Si collision/échelle imparfaite : ajuster `make-background.sh` (coordonnées) et/ou `Distribution.xml` (`alignment`/`scaling`), régénérer, recommit.

- [ ] **Step 3: Vérifier le rendu français**

Sur un système réglé en français (ou Réglages → Langue), rouvrir `build/Iris.pkg` → les écrans s'affichent en français.

- [ ] **Step 4: Installer et vérifier le résultat**

Terminer l'installation, puis :
```bash
ls -d /Applications/Iris.app
ls -d "$HOME/Library/Application Support/iris"
```
Expected : l'app présente dans `/Applications` ; dossier de support créé (postinstall). (Rappel : pas d'auto-start — Phase 7.)

- [ ] **Step 5: Notariser le nouveau `.pkg`**

```bash
./packaging/notarize.sh build/Iris.pkg
spctl --assess --type install -vv build/Iris.pkg
```
Expected : `Accepted` + staple ; `spctl` → `accepted source=Notarized Developer ID`.

---

## Task 9: Pull Request (CLAUDE.md §8)

- [ ] **Step 1: Pré-requis verts**

```bash
swift build && swift test 2>&1 | tail -5
swift format lint --recursive Sources Tests 2>/dev/null || true
git log --oneline origin/main..HEAD
```
Expected : 455 tests verts (code inchangé) ; commits 9c listés.

- [ ] **Step 2: Pousser et ouvrir la PR avec checklist de smoke**

```bash
git push -u origin feat/phase-9c-installer-screens
gh pr create --base main --title "feat(phase-9c): installeur .pkg guidé (écrans bilingues + marque)" --body "$(cat <<'BODY'
## Phase 9c — installeur .pkg guidé

Passe l'installeur de `productbuild --component` (nu) à un assistant guidé bilingue
(welcome/readme/license/conclusion + image de fond) via `productbuild --distribution`.
Packaging-only : **zéro `.swift`/`.pbxproj`** → CI inchangé (455 tests).

Spec : `docs/superpowers/specs/2026-06-06-phase-9c-installer-screens-design.md`

### Smoke testing (au poste — certs + GUI requis)
- [ ] `./packaging/build-pkg.sh` → `build/Iris.pkg` signé (`pkgutil --check-signature` OK)
- [ ] Assistant déroule Welcome → Read Me → License (MIT) → Conclusion
- [ ] Image de fond visible et lisible (texte Installer non masqué)
- [ ] Rendu **français** OK sur système en français
- [ ] Install → `Iris.app` dans `/Applications` + `~/Library/Application Support/iris` créé
- [ ] `./packaging/notarize.sh build/Iris.pkg` → `Accepted` + staple ; `spctl` → Notarized Developer ID
- [ ] Vérif structurelle headless (Task 7) : `CÂBLAGE OK`
BODY
)"
```

- [ ] **Step 3: Revue Gemini + merge** — suivre CLAUDE.md §8 (polling Gemini, appliquer/refuser factuellement), puis **merge squash sur confirmation explicite de l'utilisateur** une fois la checklist smoke cochée.

---

## Notes d'exécution

- **Ordre** : Tasks 1→6 sont commitables headless. **Task 7 (vérif structurelle) gate la Task 8** : ne pas lancer le build signé tant que `CÂBLAGE OK` n'est pas obtenu.
- **Sync version** : si `IRIS_PKG_VERSION` change, mettre à jour `version="0.1.0"` dans `Distribution.xml` (pkg-ref) en parallèle.
- **Daemon intact** : 9c ne rebuild/re-signe **pas** `irisd` → aucun risque sur les secrets ACL 8b.
- **Mode sombre** : `<background>` clair en dark mode = item de réglage au smoke (ajouter un `background-darkAqua` si jugé nécessaire — à vérifier sur la doc avant usage).
