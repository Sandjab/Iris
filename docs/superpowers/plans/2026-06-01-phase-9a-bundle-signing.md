# Phase 9a — Bundle assembly & Developer ID signing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produire un `Iris.app` signé Developer ID + hardened runtime avec `irisd` embarqué et le plist LaunchAgent en place, plus la structure de packaging (`build-pkg.sh` jusqu'à un `.pkg` signé, `notarize.sh` en squelette), sans notariser ni démarrer automatiquement.

**Architecture:** `xcodebuild archive`/`exportArchive` produit `Iris.app` ; `packaging/build-pkg.sh` build `irisd` via SwiftPM, embarque `irisd` + le plist dans le bundle (`ditto`), signe **inner-first** (`irisd` puis bundle, jamais `--deep`), puis `productbuild` produit un `.pkg` signé Developer ID Installer. La signature Developer ID + `-o runtime` sont appliqués **par le script** (jamais figés dans le `.pbxproj`) → le gate CI `xcodebuild` reste intact.

**Tech Stack:** Bash, `xcodebuild`, `codesign`, `productbuild`, `pkgutil`, SwiftPM (`swift build`). Aucune dépendance Swift nouvelle, aucun code Swift métier nouveau.

**Spec source:** `docs/superpowers/specs/2026-06-01-phase-9a-bundle-signing-design.md`

**Branche:** `feat/phase-9a-bundle-signing` (déjà créée ; spec + raffinement déjà commités).

---

## Raffinements vs la spec (vérifiés contre la doc Apple « Creating distribution-signed code for macOS »)

1. **Zéro changement `.pbxproj`** : le plist LaunchAgent est embarqué **par `build-pkg.sh`** (post-export), comme `irisd`, et non via une phase *Copy Files* Xcode. Plus simple, symétrique, et garantit que le gate CI est intact (raffine §2.5 du design). Le plist n'est requis que pour le bundle packagé (Phase 7), jamais pour un build/test CI.
2. **Aucun fichier entitlements** : app non-sandboxée, pas d'entitlement restreint en 9a ; hardened runtime via `-o runtime`. Apple signe son daemon d'exemple sans `--entitlements`.
3. **`-i io.iris.daemon`** obligatoire sur `irisd` (code non-bundle).
4. **`ditto`** (pas `cp`) pour `irisd` ; **jamais `codesign` sous `sudo`**.
5. **Pas de `--deep` pour signer** (Apple : section « Avoid deep code signing ») ; `--deep` autorisé pour *vérifier*.

## Pré-requis d'exécution (à valider AVANT de lancer le plan)

- Machine de build = macOS avec Xcode ; certs **Developer ID Application** + **Developer ID Installer** présents (cf `docs/phase-9-notarization-prep.md`). Vérifié par : `security find-identity -p codesigning -v`.
- Variable d'environnement `IRIS_TEAM_ID` exportée (Team ID Apple). Le script échoue si absente.
- `build-pkg.sh` tourne **en local uniquement** (le CI n'a pas les certs).

## File Structure

| Fichier | Responsabilité | Action |
|---|---|---|
| `packaging/io.iris.daemon.plist` | Plist LaunchAgent (contenu = SPECS §17.2), embarqué par le script | Create |
| `packaging/exportOptions.plist` | Options d'export `developer-id` (template, `__IRIS_TEAM_ID__` substitué par le script) | Create |
| `packaging/build-pkg.sh` | Orchestration build → embed → signature inner-first → `.pkg` signé | Create |
| `packaging/notarize.sh` | Squelette notarisation (notarytool + stapler), **non exécuté en 9a** | Create |
| `packaging/scripts/postinstall` | Squelette inerte (crée le dossier Application Support) | Create |
| `packaging/scripts/preinstall` | Squelette minimal (`exit 0`) | Create |
| `.gitignore` | Ignorer `build/` (sorties de packaging) | Modify |

Aucune modification de `IrisApp/IrisApp.xcodeproj/project.pbxproj` ni de code Swift.

---

## Task 1: Plist LaunchAgent

**Files:**
- Create: `packaging/io.iris.daemon.plist`

- [ ] **Step 1: Créer le plist** (contenu exact de SPECS §17.2)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.iris.daemon</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/irisd</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/irisd.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/irisd.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Vérifier que le plist est valide**

Run: `plutil -lint packaging/io.iris.daemon.plist`
Expected: `packaging/io.iris.daemon.plist: OK`

- [ ] **Step 3: Vérifier les clés critiques**

Run: `plutil -extract BundleProgram raw packaging/io.iris.daemon.plist && plutil -extract Label raw packaging/io.iris.daemon.plist`
Expected:
```
Contents/MacOS/irisd
io.iris.daemon
```

- [ ] **Step 4: Commit**

```bash
git add packaging/io.iris.daemon.plist
git commit -m "feat(phase-9a): plist LaunchAgent io.iris.daemon (BundleProgram)"
```

---

## Task 2: exportOptions.plist (template developer-id)

**Files:**
- Create: `packaging/exportOptions.plist`

- [ ] **Step 1: Créer le template d'export**

`__IRIS_TEAM_ID__` est un placeholder que `build-pkg.sh` substituera (Task 4) — il n'est jamais committé avec une vraie valeur.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>__IRIS_TEAM_ID__</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

- [ ] **Step 2: Vérifier le template (lint, le DOCTYPE accepte le placeholder)**

Run: `plutil -lint packaging/exportOptions.plist`
Expected: `packaging/exportOptions.plist: OK`

- [ ] **Step 3: Vérifier la méthode**

Run: `plutil -extract method raw packaging/exportOptions.plist`
Expected: `developer-id`

- [ ] **Step 4: Commit**

```bash
git add packaging/exportOptions.plist
git commit -m "feat(phase-9a): exportOptions.plist template (method developer-id)"
```

---

## Task 3: Scripts d'install + notarize (squelettes)

**Files:**
- Create: `packaging/scripts/preinstall`
- Create: `packaging/scripts/postinstall`
- Create: `packaging/notarize.sh`

- [ ] **Step 1: Créer `packaging/scripts/preinstall` (minimal)**

```bash
#!/bin/bash
# IRIS preinstall — Phase 9a : rien à migrer/arrêter (pas d'auto-start avant Phase 7).
set -euo pipefail
exit 0
```

- [ ] **Step 2: Créer `packaging/scripts/postinstall` (inerte)**

Pas de `--first-launch` : l'app ne gère pas encore ce flag (Phase 6.3/7). On crée seulement le dossier de support, en tant qu'utilisateur installateur (pas root).

```bash
#!/bin/bash
# IRIS postinstall — Phase 9a : crée le dossier de support. PAS d'auto-start (Phase 7).
set -euo pipefail
USER_HOME="$(eval echo "~${USER}")"
mkdir -p "${USER_HOME}/Library/Application Support/iris"
exit 0
```

- [ ] **Step 3: Créer `packaging/notarize.sh` (squelette, NON exécuté en 9a)**

```bash
#!/bin/bash
# IRIS notarize — Phase 9b (squelette ; NON exécuté en Phase 9a).
# Pré-requis : profil keychain notarytool "iris-notarization" (cf docs/phase-9-notarization-prep.md),
# et un build/Iris.pkg signé produit par build-pkg.sh.
set -euo pipefail

PKG="${1:-build/Iris.pkg}"
PROFILE="${IRIS_NOTARY_PROFILE:-iris-notarization}"

[ -f "$PKG" ] || { echo "error: pkg introuvable: $PKG" >&2; exit 1; }

# 1. Soumettre et attendre la réponse du service de notarisation.
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

# 2. Récupérer le log (à faire même en cas de succès — peut contenir des warnings).
#    (id à reporter depuis la sortie de submit ; en 9b on capturera l'id programmatiquement)
# xcrun notarytool log <submission-id> --keychain-profile "$PROFILE" build/notarization-log.json

# 3. Agrafer le ticket pour usage offline.
xcrun stapler staple "$PKG"

# 4. Vérification finale.
spctl --assess --type install -vv "$PKG" || true   # "accepted source=Notarized Developer ID" attendu après staple
```

- [ ] **Step 4: Rendre les scripts d'install exécutables (requis par productbuild)**

Run: `chmod +x packaging/scripts/preinstall packaging/scripts/postinstall packaging/notarize.sh`

- [ ] **Step 5: Vérifier la syntaxe bash des trois scripts**

Run: `bash -n packaging/scripts/preinstall && bash -n packaging/scripts/postinstall && bash -n packaging/notarize.sh && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 6: Vérifier que postinstall crée bien le dossier (exécution isolée)**

Run: `USER="$USER" bash packaging/scripts/postinstall && test -d "$HOME/Library/Application Support/iris" && echo "dir OK"`
Expected: `dir OK`

- [ ] **Step 7: Vérifier que les scripts d'install sont exécutables**

Run: `test -x packaging/scripts/postinstall && test -x packaging/scripts/preinstall && echo "exec OK"`
Expected: `exec OK`

- [ ] **Step 8: Commit**

```bash
git add packaging/scripts/preinstall packaging/scripts/postinstall packaging/notarize.sh
git commit -m "feat(phase-9a): scripts install inertes + notarize.sh (squelette 9b)"
```

---

## Task 4: build-pkg.sh — orchestration complète

**Files:**
- Create: `packaging/build-pkg.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Ajouter `build/` au `.gitignore`**

Ajouter cette ligne à la fin de `.gitignore` (la créer si absente) :

```
build/
```

- [ ] **Step 2: Créer `packaging/build-pkg.sh`**

Exécuter depuis la racine du repo. Échoue vite (`set -euo pipefail`), vérifie les préconditions, ne fait **aucun fallback ad-hoc silencieux**.

```bash
#!/bin/bash
# IRIS build-pkg — Phase 9a : assemble Iris.app (irisd embarqué + plist), signe
# inner-first Developer ID + hardened runtime, produit build/Iris.pkg signé.
# Tourne EN LOCAL (certs Developer ID requis). NON notarisé (cf notarize.sh, Phase 9b).
set -euo pipefail

# --- Config ---------------------------------------------------------------
APP_IDENTITY="Developer ID Application"
INSTALLER_IDENTITY="Developer ID Installer"
SCHEME="IrisApp"
PROJECT="IrisApp/IrisApp.xcodeproj"
BUILD="build"
ARCHIVE="$BUILD/Iris.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Iris.app"
PKG="$BUILD/Iris.pkg"
DAEMON_BIN=".build/release/irisd"

# --- 0. Préconditions (fail-fast, aucun fallback) -------------------------
: "${IRIS_TEAM_ID:?error: exporte IRIS_TEAM_ID (Team ID Apple) avant de lancer}"
security find-identity -p codesigning -v | grep -q "$APP_IDENTITY" \
  || { echo "error: identité '$APP_IDENTITY' absente du trousseau" >&2; exit 1; }
security find-identity -v | grep -q "$INSTALLER_IDENTITY" \
  || { echo "error: identité '$INSTALLER_IDENTITY' absente du trousseau" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$EXPORT"

# --- 1. Build irisd (SwiftPM, release) ------------------------------------
swift build -c release --product irisd
[ -f "$DAEMON_BIN" ] || { echo "error: $DAEMON_BIN introuvable après build" >&2; exit 1; }

# --- 2. Archive de l'app (signature non figée dans le projet → override CLI) --
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$IRIS_TEAM_ID" CODE_SIGN_STYLE=Automatic

# --- 3. Export (developer-id) — substitue le Team ID dans exportOptions ----
sed "s/__IRIS_TEAM_ID__/$IRIS_TEAM_ID/" packaging/exportOptions.plist > "$BUILD/exportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/exportOptions.plist" \
  -exportPath "$EXPORT"
[ -d "$APP" ] || { echo "error: $APP introuvable après export" >&2; exit 1; }

# --- 4. Embed irisd (ditto, code) + plist (cp, data) ----------------------
ditto "$DAEMON_BIN" "$APP/Contents/MacOS/irisd"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp packaging/io.iris.daemon.plist "$APP/Contents/Library/LaunchAgents/io.iris.daemon.plist"

# --- 5. Signature INNER-FIRST (pas de --deep ; jamais sous sudo) ----------
#   a. irisd d'abord (code non-bundle → -i obligatoire ; aucun entitlements)
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime -i io.iris.daemon \
  "$APP/Contents/MacOS/irisd"
#   b. le bundle ensuite (re-scelle CodeResources → couvre irisd + plist)
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime "$APP"

# --- 6. Vérification signature (--deep légitime ici = vérification) --------
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 7. PKG signé Developer ID Installer ----------------------------------
productbuild --component "$APP" /Applications \
  --scripts packaging/scripts \
  --sign "$INSTALLER_IDENTITY" --timestamp \
  "$PKG"

# --- 8. Vérification pkg ---------------------------------------------------
pkgutil --check-signature "$PKG"

echo "OK → $PKG (signé, NON notarisé ; voir notarize.sh pour la Phase 9b)"
```

- [ ] **Step 3: Rendre exécutable + vérifier la syntaxe**

Run: `chmod +x packaging/build-pkg.sh && bash -n packaging/build-pkg.sh && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 4: Exécuter le script end-to-end** (machine locale avec certs + `IRIS_TEAM_ID`)

Run: `IRIS_TEAM_ID="<ton-team-id>" ./packaging/build-pkg.sh`
Expected: dernière ligne `OK → build/Iris.pkg (signé, NON notarisé ; ...)`.

> ⚠️ **Partie la plus susceptible d'itérer** : la signature à l'archive/export (étapes 2-3). Selon le comportement réel de ton Xcode, il peut falloir ajuster (`-allowProvisioningUpdates`, `signingStyle` `manual` + `signingCertificate` dans `exportOptions.plist`, ou générer une fois `exportOptions.plist` via un export GUI Xcode). Le critère de réussite reste : `build/export/Iris.app` produit puis signé. Si l'étape 2 ou 3 échoue, itérer sur les flags de signature **sans** toucher au `.pbxproj` (CI-safety).

- [ ] **Step 5: Commit** (une fois le script vert end-to-end)

```bash
git add packaging/build-pkg.sh .gitignore
git commit -m "feat(phase-9a): build-pkg.sh (archive→embed→sign inner-first→pkg signé)"
```

---

## Task 5: Vérifications structurelle & signature (sur la sortie de Task 4)

Aucun fichier créé — vérifications sur `build/` produit par `build-pkg.sh`. Ces commandes alimentent la checklist smoke de la PR.

- [ ] **Step 1: irisd embarqué présent**

Run: `test -f build/export/Iris.app/Contents/MacOS/irisd && file build/export/Iris.app/Contents/MacOS/irisd`
Expected: `… Mach-O 64-bit executable …`

- [ ] **Step 2: plist embarqué présent et valide**

Run: `plutil -lint build/export/Iris.app/Contents/Library/LaunchAgents/io.iris.daemon.plist`
Expected: `… OK`

- [ ] **Step 3: signature du bundle valide, irisd reconnu comme code imbriqué**

Run: `codesign --verify --deep --strict --verbose=2 build/export/Iris.app`
Expected: `build/export/Iris.app: valid on disk` + `satisfies its Designated Requirement` (pas d'erreur `nested code is unsigned`).

- [ ] **Step 4: irisd signé Developer ID + hardened runtime + timestamp**

Run: `codesign -dvvv build/export/Iris.app/Contents/MacOS/irisd 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime|Timestamp="`
Expected: lignes montrant `Authority=Developer ID Application: …`, `flags=… (runtime)`, et un `Timestamp=`.

- [ ] **Step 5: l'app signée Developer ID + hardened runtime**

Run: `codesign -dvvv build/export/Iris.app 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime"`
Expected: `Authority=Developer ID Application: …` + `flags=… (runtime)`.

- [ ] **Step 6: pkg signé Developer ID Installer**

Run: `pkgutil --check-signature build/Iris.pkg`
Expected: `Status: signed by a developer certificate issued by Apple` + chaîne `Developer ID Installer: …`.

- [ ] **Step 7: spctl rejette (attendu — non notarisé)**

Run: `spctl --assess --type execute -vv build/export/Iris.app; echo "exit=$?"`
Expected: `rejected` + `source=... (no usable signature / notariz…)` et `exit=3`. **C'est normal en 9a** — `codesign --verify` (Step 3) est l'oracle de la signature, pas `spctl` (qui exige la notarisation, Phase 9b).

> Pas de commit (vérifications seules).

---

## Task 6: Smoke runtime (preuve « démontrable », CLAUDE.md §12)

Prouve que le `irisd` **embarqué + signé + hardened-runtime** tourne réellement. Validé **sur la machine de build** (qui fait confiance à sa propre signature Developer ID) — ne prouve pas une machine tierce (notarisation = 9b).

- [ ] **Step 1: Lancer le irisd embarqué en foreground (terminal A)**

Run: `build/export/Iris.app/Contents/MacOS/irisd --foreground`
Expected: démarre sans être tué (pas de « killed: 9 » ni crash hardened-runtime), log de démarrage, bind de la socket Unix.

- [ ] **Step 2: Vérifier les permissions de la socket (terminal B)**

Le chemin par défaut est `~/Library/Application Support/iris/admin.sock` (`Sources/iris/Support/ConnectionOptions.swift:28` → `Config.default.broker.expandedAdminSocket`).

Run: `ls -l "$HOME/Library/Application Support/iris/admin.sock"`
Expected: socket présente, permissions `srw-------` (0600), owner = utilisateur courant.

- [ ] **Step 3: Round-trip RPC via le CLI existant (terminal B)**

`iris doctor` vérifie explicitement la résolution du socket + l'atteignabilité du daemon (`Sources/iris/Commands/DoctorCommand.swift`).

Run: `swift run iris doctor`
Expected: les checks `socket-path-resolution` et atteignabilité daemon passent (pas de « connection refused »), prouvant que le daemon embarqué accepte et sert une requête.

- [ ] **Step 4: Arrêter le daemon (terminal A)** : `Ctrl-C`.

> Pas de commit (vérification runtime).

---

## Task 7: Clôture — CI vert + checklist + PR

- [ ] **Step 1: `swift build` + `swift test` verts** (inchangés — pas de code Swift nouveau)

Run: `swift build && swift test`
Expected: build OK, tous les tests passent (même nombre qu'avant 9a).

- [ ] **Step 2: `swift-format` propre sur les fichiers ajoutés** (les `.sh`/`.plist` ne sont pas concernés ; vérifier qu'aucun `.swift` n'a été touché)

Run: `git diff --name-only origin/main...HEAD | grep -E '\.swift$' || echo "aucun .swift modifié"`
Expected: `aucun .swift modifié`

- [ ] **Step 3: Pousser la branche et ouvrir la PR avec la checklist smoke**

```bash
git push -u origin feat/phase-9a-bundle-signing
```

Description PR — checklist smoke (cases à cocher avant merge) :

```markdown
## Phase 9a — Bundle assembly & Developer ID signing

### Smoke testing
- [ ] `IRIS_TEAM_ID=… ./packaging/build-pkg.sh` s'exécute jusqu'au bout → `build/Iris.pkg`.
- [ ] `irisd` présent dans `Iris.app/Contents/MacOS/` (`file` → Mach-O executable).
- [ ] plist présent dans `Contents/Library/LaunchAgents/` + `plutil -lint` OK.
- [ ] `codesign --verify --deep --strict Iris.app` → valide, irisd reconnu comme code imbriqué.
- [ ] `codesign -dvvv` sur app **et** irisd → `Developer ID Application` + flag `runtime` + `Timestamp`.
- [ ] `pkgutil --check-signature build/Iris.pkg` → `Developer ID Installer`.
- [ ] `spctl --assess --type execute Iris.app` → **rejeté** (attendu, non notarisé) — documenté comme normal.
- [ ] `irisd` embarqué lancé en `--foreground` : démarre, bind socket `0600`, le CLI s'y connecte (RPC round-trip).
- [ ] Gate CI `xcodebuild` macos-15 **vert** (validé sur le CI, pas en local).
```

> ⚠️ **CLAUDE.md / mémoire projet** : pour tout changement touchant IrisApp, **le CI macos-15 est le seul juge**. Ici on n'a PAS touché le `.pbxproj`, donc le risque est minimal — mais vérifier explicitement que le gate CI reste vert après push avant de cocher la dernière case.

- [ ] **Step 4: Revue Gemini** (CLAUDE.md §8) : attendre + traiter chaque commentaire (appliquer+commit+reply, ou refuser factuellement). Merge **uniquement après confirmation explicite de l'utilisateur** (`gh pr merge --squash`).

---

## Self-review (couverture spec → tâches)

| Exigence spec | Tâche |
|---|---|
| Plist LaunchAgent (§17.2) embarqué | Task 1 + Task 4 step 4 |
| Bundle avec irisd dans MacOS/ (§3.3) | Task 4 step 4 |
| Signature inner-first, pas de --deep (§2.2) | Task 4 step 5 + Task 5 step 3-5 |
| `-i io.iris.daemon`, `-o runtime`, ditto (raffinements) | Task 4 step 4-5 |
| Pas d'entitlements (raffinement vérifié) | Task 4 step 5 (aucun `--entitlements`) |
| `.pkg` signé Developer ID Installer (§18.1) | Task 4 step 7 + Task 5 step 6 |
| `build-pkg.sh` jusqu'au pkg signé (§1) | Task 4 |
| `notarize.sh` squelette (§1) | Task 3 step 3 |
| `postinstall` inerte, pas de --first-launch (§2.5) | Task 3 step 2 |
| `preinstall` minimal (§3.1) | Task 3 step 1 |
| exportOptions.plist developer-id (§3.1) | Task 2 |
| pbxproj CI-safe — ici zéro changement (§2.4, raffiné) | aucune tâche pbxproj (par design) |
| Vérif structurelle + signature (§5.1) | Task 5 |
| Smoke runtime (§5.1, CLAUDE.md §12) | Task 6 |
| CI vert + checklist PR (§5.2, §5.3, §6) | Task 7 |
