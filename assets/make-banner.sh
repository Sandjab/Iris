#!/bin/bash
# Régénère assets/banner.png (1280x640) pour le README.
# Direction « D2/doré » (raccord installeur) : silhouette Mercure bleu nuit à gauche,
# wordmark IRIS + filet doré + tagline, sur fond gris-bleu pâle.
set -euo pipefail
cd "$(dirname "$0")"
SRC="../packaging/installer/src/mercury-silhouette.png"
OUT="banner.png"
NAVY='#0E2A47'; GOLD='#C9912E'; BG='#F6F8FC'; GREY='#5B6B82'
FONT="/System/Library/Fonts/SFNS.ttf"   # San Francisco ; chemin absolu (magick ne résout pas le nom seul)
TMP_DIR="$(mktemp -d -t iris-banner)"
trap 'rm -rf "$TMP_DIR"' EXIT
NAVY_PNG="$TMP_DIR/mercury-navy.png"

# Silhouette N&B -> masque alpha -> remplissage navy
magick "$SRC" \
  \( +clone -colorspace Gray -negate \) -alpha off -compose CopyOpacity -composite \
  -channel RGB -fill "$NAVY" -colorize 100 +channel "$NAVY_PNG"

# Composition 1280x640 : emblème gauche, bloc texte à droite
magick -size 1280x640 "xc:$BG" \
  \( "$NAVY_PNG" -resize 470x470 \) -gravity West -geometry +70+0 -composite \
  -gravity NorthWest -font "$FONT" -kerning 12 \
  -fill "$NAVY" -pointsize 132 -annotate +560+175 'IRIS' \
  -kerning 0 \
  -fill "$GOLD" -draw 'rectangle 566,338 706,350' \
  -fill "$NAVY" -pointsize 42 -annotate +564+372 'Secrets Are Safe.' \
  -fill "$GREY" -pointsize 27 -annotate +566+440 'Local credential broker for macOS' \
  "$OUT"
echo "OK -> assets/$OUT (1280x640)"
