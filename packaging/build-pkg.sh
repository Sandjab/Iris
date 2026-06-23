#!/bin/bash
# IRIS build-pkg — assemble Iris.app (irisd embarqué + plist), signe inner-first,
# produit un .pkg GUIDÉ (écrans + fond, Phase 9c) signé Developer ID Installer.
# Tourne EN LOCAL (certs Developer ID requis). NON notarisé (cf notarize.sh, Phase 9b).
set -euo pipefail

# --- Config ---------------------------------------------------------------
APP_IDENTITY="${IRIS_APP_IDENTITY:-Developer ID Application}"
INSTALLER_IDENTITY="${IRIS_INSTALLER_IDENTITY:-Developer ID Installer}"
SCHEME="IrisApp"
PROJECT="IrisApp/IrisApp.xcodeproj"
BUILD="build"
ARCHIVE="$BUILD/Iris.xcarchive"
EXPORT="$BUILD/export"
PKG="$BUILD/Iris.pkg"
VERSION="${IRIS_PKG_VERSION:-1.0.1}"
COMPONENT_DIR="$BUILD/component"
COMPONENT_PKG="$COMPONENT_DIR/Iris-component.pkg"
RESOURCES="packaging/installer/resources"
DISTRIBUTION="packaging/installer/Distribution.xml"
# APP est dérivé après l'export (le nom réel suit PRODUCT_NAME → IrisApp.app actuellement).
DAEMON_BIN=".build/release/irisd"
SANDBOX_SHIM_BIN=".build/release/iris-sandbox-exec"

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

# --- 1a. Build iris-sandbox-exec (shim Seatbelt des plugins) --------------
#   Sans ce binaire embarqué à côté d'irisd, PluginSandbox ne trouve pas le
#   shim en distribution (Daemon.swift résout le chemin voisin de l'exécutable)
#   → tout lancement de plugin échoue. Cf. PluginSandbox.swift.
swift build -c release --product iris-sandbox-exec
[ -f "$SANDBOX_SHIM_BIN" ] || { echo "error: $SANDBOX_SHIM_BIN introuvable après build" >&2; exit 1; }

# --- 1b. Build + stage CLI iris (→ /usr/local/bin) ------------------------
swift build -c release --product iris
IRIS_CLI_BIN=".build/release/iris"
[ -f "$IRIS_CLI_BIN" ] || { echo "error: $IRIS_CLI_BIN introuvable après build" >&2; exit 1; }
CLI_ROOT="$BUILD/cli-root/usr/local/bin"
mkdir -p "$CLI_ROOT"
ditto "$IRIS_CLI_BIN" "$CLI_ROOT/iris"
# Signature Developer ID (hardened runtime, identifiant non-bundle, sans entitlements).
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime -i io.iris.cli "$CLI_ROOT/iris"

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

# --- 4. Embed irisd + shim sandbox (ditto, code) + plist (cp, data) -------
ditto "$DAEMON_BIN" "$APP/Contents/MacOS/irisd"
ditto "$SANDBOX_SHIM_BIN" "$APP/Contents/MacOS/iris-sandbox-exec"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp packaging/io.iris.daemon.plist "$APP/Contents/Library/LaunchAgents/io.iris.daemon.plist"

# --- 5. Signature INNER-FIRST (pas de --deep ; jamais sous sudo) ----------
#   a. irisd d'abord (code non-bundle → -i obligatoire ; aucun entitlements)
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime -i io.iris.daemon \
  "$APP/Contents/MacOS/irisd"
#   a-bis. shim sandbox (idem : code non-bundle, -i obligatoire, sans entitlements)
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime -i io.iris.sandbox-exec \
  "$APP/Contents/MacOS/iris-sandbox-exec"
#   b. le bundle ensuite (re-scelle CodeResources → couvre irisd + shim + plist)
codesign -s "$APP_IDENTITY" -f --timestamp -o runtime "$APP"

# --- 6. Vérification signature (--deep légitime ici = vérification) --------
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 7. PKG guidé signé Developer ID Installer ----------------------------
#   a. Licence : ressource UNIQUE non localisée (racine de resources) -> pas de
#      sélecteur de langue sur l'écran Licence (la MIT n'a pas de version FR légale).
#      welcome/readme/conclusion restent localisés (en.lproj/fr.lproj).
rm -f "$RESOURCES"/*.lproj/license.txt
cp LICENSE "$RESOURCES/license.txt"
#   b. Composant app NON-RELOCATABLE (les scripts pre/postinstall s'attachent ICI).
#      Sans BundleIsRelocatable=false, Installer relocalise l'app vers une instance
#      existante de io.iris.app trouvée ailleurs sur le disque (p.ex. build/export/Iris.app)
#      au lieu de /Applications → /Applications/Iris.app absent → le postinstall
#      (open -a /Applications/Iris.app --first-launch) échoue (PKInstallErrorDomain 112).
mkdir -p "$COMPONENT_DIR"
APP_ROOT="$BUILD/app-root"
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT"
ditto "$APP" "$APP_ROOT/$(basename "$APP")"
APP_COMPONENT_PLIST="$BUILD/app-component.plist"
pkgbuild --analyze --root "$APP_ROOT" "$APP_COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$APP_COMPONENT_PLIST"
pkgbuild --root "$APP_ROOT" --component-plist "$APP_COMPONENT_PLIST" \
  --install-location /Applications \
  --scripts packaging/scripts \
  --identifier io.iris.app --version "$VERSION" \
  "$COMPONENT_PKG"
#   CLI component: installs iris into /usr/local/bin.
CLI_COMPONENT_PKG="$COMPONENT_DIR/Iris-cli.pkg"
pkgbuild --root "$BUILD/cli-root/usr/local/bin" --install-location /usr/local/bin \
  --identifier io.iris.cli --version "$VERSION" \
  "$CLI_COMPONENT_PKG"
#   c. Produit guidé (écrans + fond via Distribution XML) signé.
#      Version templatée depuis $VERSION → pas de drift avec le pkg-ref du Distribution.
DISTRIBUTION_BUILD="$BUILD/Distribution.xml"
mkdir -p "$BUILD"
sed "s/version=\"0.1.0\"/version=\"$VERSION\"/g" "$DISTRIBUTION" > "$DISTRIBUTION_BUILD"
productbuild --distribution "$DISTRIBUTION_BUILD" \
  --package-path "$COMPONENT_DIR" \
  --resources "$RESOURCES" \
  --sign "$INSTALLER_IDENTITY" --timestamp \
  "$PKG"

# --- 8. Vérification pkg ---------------------------------------------------
pkgutil --check-signature "$PKG"

echo "OK → $PKG (signé, NON notarisé ; voir notarize.sh pour la Phase 9b)"
