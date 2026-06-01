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
