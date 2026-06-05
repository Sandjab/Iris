#!/bin/bash
# Régénère background.png (@1x 620x418) + background@2x.png (@2x 1240x836)
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
