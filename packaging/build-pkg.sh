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
PKG="$BUILD/Iris.pkg"
# APP est dérivé après l'export (le nom réel suit PRODUCT_NAME → IrisApp.app actuellement).
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
# Nom réel du bundle = PRODUCT_NAME (IrisApp.app) → dérivé, pas figé.
APP="$(/usr/bin/find "$EXPORT" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP" ] && [ -d "$APP" ] || { echo "error: aucun .app exporté dans $EXPORT" >&2; exit 1; }

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
