#!/bin/bash
# Régénère les fonds de l'installeur guidé (clair + sombre) à 1240x836 (retina de 620x418).
#
# Méthode : on rend render-bg.html via Chrome headless (VRAIE police SF + masque CSS),
# garantissant la fidélité au playground de placement. magick ne sert qu'à dériver le
# masque alpha de la silhouette ; on l'injecte en data URI base64 dans un HTML temporaire
# car un mask-image PNG *externe* en file:// est bloqué par la politique same-origin de
# Chrome (l'emblème disparaîtrait). render-bg.html garde la réf 'sil-mask.png' pour le
# debug (ouvrir via un serveur HTTP local, pas file://).
#
# Sortie : resources/background.png (clair) + resources/background-dark.png (sombre, pour
# l'attribut <background-darkAqua> du Distribution XML). scaling="tofit" adapte à la fenêtre.
#
# Pré-requis : ImageMagick (magick), python3, Google Chrome. Surchargeable : CHROME=/chemin
set -euo pipefail
cd "$(dirname "$0")"

SRC="src/mercury-silhouette.png"
MASK="sil-mask.png"                 # masque alpha (gitignoré, régénéré ici)
OUT="resources"
RENDER="render-bg.html"
TMP="render-bg.tmp.html"            # copie avec masque inliné (gitignoré, supprimé en fin)
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || CHROME="/Applications/Chromium.app/Contents/MacOS/Chromium"
[ -x "$CHROME" ] || { echo "error: Chrome/Chromium introuvable (surcharge: CHROME=...)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "error: $SRC introuvable" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT

# 1. Masque alpha : silhouette -> forme blanche opaque sur transparent, marges supprimées
#    (le -trim donne la bbox = la boîte de l'emblème dans render-bg.html).
magick "$SRC" \
  \( +clone -colorspace Gray -negate \) -alpha off -compose CopyOpacity -composite \
  -channel RGB -fill white -colorize 100 +channel -trim +repage -resize 560x "$MASK"

# 2. Inliner le masque en data URI (contourne le blocage same-origin de mask-image).
python3 - "$RENDER" "$MASK" "$TMP" <<'PY'
import base64, sys
render, mask, out = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = base64.b64encode(open(mask, "rb").read()).decode()
html = open(render).read()
open(out, "w").write(html.replace("sil-mask.png", "data:image/png;base64," + b64))
PY

# 3. Capture des deux thèmes à la résolution exacte du fichier de fond.
shot () { # <theme-query> <out>
  "$CHROME" --headless=new --hide-scrollbars --disable-gpu --force-color-profile=srgb \
    --virtual-time-budget=2000 --window-size=1240,836 \
    --screenshot="$2" "file://$PWD/$TMP$1" >/dev/null 2>&1
  [ -f "$2" ] || { echo "error: capture échouée -> $2" >&2; exit 1; }
}
shot ""             "$OUT/background.png"
shot "?theme=dark"  "$OUT/background-dark.png"

echo "OK -> $OUT/background.png + $OUT/background-dark.png (1240x836)"
