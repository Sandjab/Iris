"""Génère les 3 imagesets template du jeu d'icônes menu-bar « buste » (tête ailée),
depuis l'AppIcon 256px, avec la géométrie validée au playground :
  active  = silhouette pleine
  paused  = contour épais (MinFilter 9 ~ 4 pt)
  stopped = contour épais barré « \\ » : barre 7.5 pt, gap 4 pt, longueur 90% de la
            diagonale, offset (-7, 1) pt depuis le centre de la bbox.
connecting réutilise « active » (rendu à 45% par le code).
Sortie : IrisApp/IrisApp/Assets.xcassets/MenubarBust{Active,Paused,Stopped}.imageset/
"""
import json, math, os
import numpy as np
from PIL import Image, ImageFilter, ImageDraw

SRC = "assets/iris-icon-256.png"
XC = "IrisApp/IrisApp/Assets.xcassets"

# --- silhouette depuis l'icône (tête blanche sur fond bleu) ---
a = np.asarray(Image.open(SRC).convert("RGBA")).astype(np.float32)
lum = (a[..., 0] + a[..., 1] + a[..., 2]) / 3.0 / 255.0
mask = ((lum > 0.5) & (a[..., 3] > 40)).astype(np.uint8) * 255
mask_img = Image.fromarray(mask)

ys, xs = np.where(mask > 0)
# bbox de contenu, élargie à des dimensions PAIRES (1x/2x exacts)
BOX = (int(xs.min()) - 2, int(ys.min()) - 2, int(xs.min()) - 2 + 144, int(ys.min()) - 2 + 162)

def template(L):
    """canal alpha L -> RGBA noir teintable (template)."""
    arr = np.zeros((L.height, L.width, 4), np.uint8)
    arr[..., 3] = np.asarray(L)
    return Image.fromarray(arr)

# contour épais (≈ 4 pt)
bold = Image.fromarray(
    np.clip(np.asarray(mask_img).astype(np.int16)
            - np.asarray(mask_img.filter(ImageFilter.MinFilter(9))).astype(np.int16), 0, 255).astype(np.uint8))

# --- géométrie de la barre (prompt), dans l'espace de la bbox ---
W, H = 144, 162
diag = math.hypot(W, H)
ux, uy = W / diag, H / diag
cx = BOX[0] + W / 2 - 7          # offset X = -7
cy = BOX[1] + H / 2 + 1          # offset Y = +1
half = 0.90 * diag / 2           # longueur 90%
bar_w, gap = 7.5, 4
p1 = (cx - half * ux, cy - half * uy)
p2 = (cx + half * ux, cy + half * uy)

stopped = bold.copy()
d = ImageDraw.Draw(stopped)
d.line([p1, p2], fill=0, width=round(bar_w + 2 * gap))   # gomme (creuse le contour)
d.line([p1, p2], fill=255, width=round(bar_w))           # barre

MASTERS = {
    "MenubarBustActive": mask_img,   # silhouette pleine
    "MenubarBustPaused": bold,       # contour épais
    "MenubarBustStopped": stopped,   # contour épais barré
}

for name, src in MASTERS.items():
    m2 = template(src.crop(BOX))                       # @2x : 144×162
    m1 = m2.resize((W // 2, H // 2), Image.LANCZOS)    # @1x : 72×81
    folder = f"{XC}/{name}.imageset"
    os.makedirs(folder, exist_ok=True)
    m1.save(f"{folder}/{name}-1.png")
    m2.save(f"{folder}/{name}-2.png")
    json.dump({
        "images": [
            {"filename": f"{name}-1.png", "idiom": "universal", "scale": "1x"},
            {"filename": f"{name}-2.png", "idiom": "universal", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }, open(f"{folder}/Contents.json", "w"), indent=2)
    print("écrit:", folder)

print("bbox:", BOX, "| barre:", tuple(round(v, 1) for v in p1), "->", tuple(round(v, 1) for v in p2))
