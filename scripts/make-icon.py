#!/usr/bin/env python3
"""Turn the drawn logo into a macOS app icon (.icns source .iconset).

The source is a full square with the rounded-corner mask and a white surround
already baked in. A macOS icon wants the *shape* on a transparent canvas with
the artwork inset (Apple's template: content within 824 of 1024), so the white
surround is cropped off, the content is re-masked with a clean rounded rectangle
and centred.
"""
from PIL import Image, ImageDraw

SRC = "logo-src.jpeg"
OUT = "KRemote.iconset"

src = Image.open(SRC).convert("RGB")
w, h = src.size

# --- 1. Find the content box: the corners are white, so the artwork is the
#        bounding box of everything that is not near-white. ------------------
px = src.load()
step = 4
minx, miny, maxx, maxy = w, h, 0, 0
for y in range(0, h, step):
    for x in range(0, w, step):
        r, g, b = px[x, y]
        if not (r > 245 and g > 245 and b > 245):
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
content = src.crop((minx, miny, maxx + 1, maxy + 1))
print(f"source {w}x{h} -> content box ({minx},{miny})-({maxx},{maxy}) "
      f"= {content.size[0]}x{content.size[1]}")

# --- 2. Place it on a transparent 1024 canvas at the macOS content scale. ----
CANVAS = 1024
CONTENT = 824                     # Apple: artwork occupies 824 of 1024
margin = (CANVAS - CONTENT) // 2  # 100

art = content.resize((CONTENT, CONTENT), Image.LANCZOS).convert("RGBA")

# Rounded-corner alpha mask. Apple uses a superellipse; a rounded rectangle at
# ~22.4% radius is the usual close approximation.
radius = round(CONTENT * 0.2237)
mask = Image.new("L", (CONTENT, CONTENT), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [0, 0, CONTENT - 1, CONTENT - 1], radius=radius, fill=255)
art.putalpha(mask)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
canvas.paste(art, (margin, margin), art)

# --- 3. Emit every size macOS wants. ----------------------------------------
import os
os.makedirs(OUT, exist_ok=True)
specs = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for name, size in specs:
    canvas.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))
    print("  wrote", name, size)
print("done")
