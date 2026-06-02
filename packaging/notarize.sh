#!/bin/bash
# IRIS notarize — Phase 9b : soumet build/Iris.pkg à la notarisation Apple,
# récupère le log, agrafe le ticket, et vérifie l'acceptation Gatekeeper.
# Pré-requis : profil keychain notarytool "iris-notary" (cf docs/phase-9-notarization-prep.md),
# et un build/Iris.pkg signé produit par build-pkg.sh.
set -euo pipefail

PKG="${1:-build/Iris.pkg}"
PROFILE="${IRIS_NOTARY_PROFILE:-iris-notary}"
SUBMIT_JSON="build/notarization-submit.json"
LOG_JSON="build/notarization-log.json"

[ -f "$PKG" ] || { echo "error: pkg introuvable: $PKG" >&2; exit 1; }

# S'assurer que le dossier des fichiers JSON existe (SUBMIT_JSON et LOG_JSON partagent ce dossier).
mkdir -p "$(dirname "$SUBMIT_JSON")"

# 1. Soumettre et attendre le verdict (JSON pour parsing robuste).
#    '|| true' : sur un verdict "Invalid", notarytool peut sortir ≠ 0 ; on tolère pour
#    toujours récupérer le log à l'étape 3. Un échec réel (réseau) produit un JSON
#    vide/invalide → plutil échoue à l'étape 2 et set -e arrête proprement le script.
echo "→ soumission notarisation: $PKG (profil: $PROFILE)"
xcrun notarytool submit "$PKG" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json > "$SUBMIT_JSON" || true

# 2. Extraire id + status (plutil natif, pas de jq).
id="$(plutil -extract id raw -o - "$SUBMIT_JSON")"
status="$(plutil -extract status raw -o - "$SUBMIT_JSON")"
echo "→ submission id: $id — status: $status"

# 3. Récupérer le log dans TOUS les cas (peut contenir des warnings même en succès).
xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$LOG_JSON"

# 4. Garde-fou : ne jamais agrafer un pkg non accepté.
if [ "$status" != "Accepted" ]; then
  echo "error: notarisation non acceptée (status=$status). Log:" >&2
  cat "$LOG_JSON" >&2
  exit 1
fi

# 5. Agrafer le ticket pour usage offline.
xcrun stapler staple "$PKG"

# 6. Valider l'agrafage.
xcrun stapler validate "$PKG"

# 7. Vérification finale Gatekeeper (échoue si rejeté — pas de '|| true').
spctl --assess --type install -vv "$PKG"   # attendu : "accepted source=Notarized Developer ID"

echo "OK → $PKG notarisé + stapled + accepté par Gatekeeper"
