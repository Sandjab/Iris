#!/bin/bash
# Régénère background.png (1240x836, résolution retina) pour l'installeur guidé,
# depuis src/mercury-silhouette.png.
# Image unique haute résolution : productbuild --resources ne copie PAS les fichiers
# non référencés (un background@2x.png ne serait pas embarqué) ; scaling="tofit" du
# Distribution XML l'adapte à la fenêtre (net en retina, downscale propre en 1x).
# Direction « D2/doré » : silhouette Mercure bleu nuit + filet doré sur gris-bleu.
set -euo pipefail
cd "$(dirname "$0")"
SRC="src/mercury-silhouette.png"
OUT="resources"
NAVY='#0E2A47'; GOLD='#C9912E'; BG='#F6F8FC'; GREY='#5B6B82'
FONT="/System/Library/Fonts/SFNS.ttf"   # San Francisco (validé) ; chemin absolu car
                                         # magick (sans fontconfig) ne résout pas le nom seul.
TMP_DIR="$(mktemp -d -t iris-background)"
trap 'rm -rf "$TMP_DIR"' EXIT
NAVY_PNG="$TMP_DIR/mercury-navy.png"

# 1. Silhouette N&B -> masque alpha -> remplissage navy (forme navy sur transparent)
magick "$SRC" \
  \( +clone -colorspace Gray -negate \) -alpha off -compose CopyOpacity -composite \
  -channel RGB -fill "$NAVY" -colorize 100 +channel "$NAVY_PNG"

# 2. Composition 1240x836 : emblème gauche, reste libre pour le contenu Installer
magick -size 1240x836 "xc:$BG" \
  \( "$NAVY_PNG" -resize 480x480 \) -gravity NorthWest -geometry +110+150 -composite \
  -font "$FONT" -gravity NorthWest \
  -fill "$NAVY" -pointsize 100 -annotate +130+620 'Iris' \
  -fill "$GOLD" -draw 'rectangle 132,772 292,784' \
  -fill "$GREY" -pointsize 30 -annotate +132+800 'Local credential broker' \
  "$OUT/background.png"
echo "OK -> $OUT/background.png (1240x836)"
