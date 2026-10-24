"""Generates the light-beam textures in Media/Highlight (white with an alpha
profile, so the addon can tint them and add-blend them over the world).

    python tools/make_highlight_textures.py
"""
import math
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "Media", "Highlight")
os.makedirs(OUT, exist_ok=True)


def save(name, alpha):
    h, w = alpha.shape
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[:, :, :3] = 255
    rgba[:, :, 3] = np.clip(alpha * 255, 0, 255).astype(np.uint8)
    image = Image.fromarray(rgba, "RGBA")
    image.save(os.path.join(OUT, name + ".tga"))


# Beam: 64 x 256. Narrow bright core with a wide soft halo, brightest at the
# bottom and fading out toward the top, and a soft fade-in at the very base.
w, h = 64, 256
x = (np.arange(w) + 0.5) / w * 2 - 1            # -1 .. 1 across
y = 1 - (np.arange(h) + 0.5) / h                 # 1 at the top row .. 0 at the bottom row
core = np.exp(-(x / 0.22) ** 2)
halo = np.exp(-(x / 0.62) ** 2)
across = 0.85 * core + 0.50 * halo
height = np.clip(1 - y, 0, 1)                    # 0 at the top .. 1 at the bottom? (rows run top->bottom)
rise = (np.arange(h) + 0.5) / h                  # 0 at the top row .. 1 at the bottom row
fade_top = rise ** 0.8                           # dark at the top, bright toward the base
fade_base = np.clip((1 - rise) / 0.06, 0, 1)     # last 6% above the bottom edge fades to 0
beam = np.outer(fade_top * fade_base, across)
save("Beam", beam / beam.max())

# Glow: 128 x 128 radial.
n = 128
c = (np.arange(n) + 0.5) / n * 2 - 1
xx, yy = np.meshgrid(c, c)
r = np.sqrt(xx ** 2 + yy ** 2)
glow = np.exp(-(r / 0.42) ** 2) * np.clip(1 - r, 0, 1)
save("Glow", glow / glow.max())

# Ring: 128 x 128, a soft thin circle.
ring = np.exp(-((r - 0.78) / 0.07) ** 2) * np.clip((1 - r) / 0.2, 0, 1)
save("Ring", ring / ring.max())
print("wrote", sorted(os.listdir(OUT)))
