"""Génère les 3 imagesets template du jeu d'icônes menu-bar « buste » (tête ailée),
depuis l'AppIcon 256px, avec la géométrie validée au playground :
  active  = silhouette pleine
  paused  = contour épais (MinFilter 9 ~ 4 pt)
  stopped = contour épais barré « \\ » : barre 7.5 pt, gap 4 pt, longueur 90% de la
            diagonale, offset (-7, 1) pt depuis le centre de la bbox.
connecting réutilise « active » (rendu à 45% par le code).
Sortie :
  - IrisApp/IrisApp/Assets.xcassets/MenubarBust{Active,Paused,Stopped}.imageset/ (template app)
  - assets/menubar-bust-{active,paused,stopped,connecting}{,-dark}.png (affichage manuel,
    noir sur fond clair / blanc sur fond sombre, comme les icônes « clé »).
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

# --- Assets d'affichage du manuel (manuel.html ch.18 / user-guide §8.3) --------
# Mêmes états que le catalogue, en PNG tinté sur fond transparent, deux variantes
# par état (noir = fond clair, blanc = fond sombre), comme les icônes « clé »
# (make-menubar-icons.swift). Affichées à ~24 px dans le manuel.
DOC_OUT = "assets"
DOC_CANVAS = 256
DOC_FIT = 0.86  # buste en portrait → un peu plus grand que le 0.8 des clés


def doc_asset(master_L, alpha_frac, white):
    g = master_L.convert("L").crop(BOX)
    s = min(DOC_CANVAS * DOC_FIT / g.width, DOC_CANVAS * DOC_FIT / g.height)
    gw, gh = round(g.width * s), round(g.height * s)
    g = g.resize((gw, gh), Image.LANCZOS)
    alpha = (np.asarray(g).astype(np.float32) * alpha_frac).clip(0, 255).astype(np.uint8)
    rgba = np.zeros((gh, gw, 4), np.uint8)
    rgba[..., :3] = 255 if white else 0
    rgba[..., 3] = alpha
    canvas = Image.new("RGBA", (DOC_CANVAS, DOC_CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(Image.fromarray(rgba), ((DOC_CANVAS - gw) // 2, (DOC_CANVAS - gh) // 2))
    return canvas


DOC_STATES = [
    ("active", mask_img, 1.0),    # silhouette pleine
    ("paused", bold, 1.0),        # contour épais
    ("stopped", stopped, 1.0),    # contour barré
    ("connecting", mask_img, 0.45),  # silhouette atténuée
]
for name, master, af in DOC_STATES:
    doc_asset(master, af, white=False).save(f"{DOC_OUT}/menubar-bust-{name}.png")
    doc_asset(master, af, white=True).save(f"{DOC_OUT}/menubar-bust-{name}-dark.png")
    print(f"écrit doc: menubar-bust-{name}{{,-dark}}.png")
