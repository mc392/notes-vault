"""GroundWork Notes app icon.

The familiar notes-app layout — a page, a coloured band across the top, ruled
lines — in GroundWork's colours, with GroundWork's leaf stamped on the page.

What is taken from GroundWork rather than invented:

  * the brand green #5C7A6D, used for the band and the leaf;
  * the pale stop #DCE6DF from their A-leaf-refined.svg, used for the ruling,
    and its light stop #F5F8F5 for the leaf's midrib;
  * the foreground white #FBFDFB, here used as the paper;
  * the leaf outline, which is the exact Bezier from that same file rather than
    a redrawing of it.

The leaf inverts GroundWork's treatment — a green body with a pale midrib,
where their icon has a white body with a green one — because here it sits on
paper rather than on the sage gradient.

Two things worth knowing about this direction, both deliberate:

  * It does not share GroundWork's dark sage background, so on a home screen the
    two read as the same brand's apps rather than as an obvious pair. That was
    traded for being legible as a notes app at a glance.
  * The layout is a widespread convention rather than anyone's property, but
    Apple's review guideline 4.1 does police icons confusingly similar to their
    own. The green band and the leaf are what keep this on the right side of
    that, so they should stay doing real work if the design is revised.

Flat fills only, and no shadows.

Drawn at 8x and downsampled, which is cheaper than fighting Pillow for
antialiasing and stays clean at the 16pt size macOS asks for.

Regenerate the asset catalog in place with:

    pip install Pillow && python3 tools/icon.py

The PNGs are committed so the app builds without Python, but they are output,
not source — change the palette here rather than editing them.
"""
import json
import math
import os
from PIL import Image, ImageDraw

# ---------------------------------------------------------------- palette

BRAND = (0x5C, 0x7A, 0x6D)      # the band, and the leaf body
PAPER = (0xFB, 0xFD, 0xFB)      # the page
RULE = (0xDC, 0xE6, 0xDF)       # the ruled lines
VEIN = (0xF5, 0xF8, 0xF5)       # the leaf's midrib, on green

S = 8            # supersample factor
SIZE = 1024      # master size
W = SIZE * S

# ---------------------------------------------------------------- layout
# Four lines rather than a dense ruling, spaced so the gap below the band
# matches the gap under the last line and the page reads as full.

BAND_H = 0.205
LINE_TOP, LINE_GAP = 0.300, 0.202
LINE_COUNT = 4
LINE_WIDTH = 0.016
LINE_X0, LINE_X1 = 0.130, 0.870

LEAF_SCALE, LEAF_X, LEAF_Y, LEAF_ANGLE = 0.00108, 0.690, 0.735, 34


def cubic(p0, p1, p2, p3, steps=160):
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append((
            u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
        ))
    return out


def place(points, scale, cx, cy, degrees):
    """Scale about the leaf's own centre, rotate, then position."""
    r = math.radians(degrees)
    cos_r, sin_r = math.cos(r), math.sin(r)
    return [(cx + (x - 256) * scale * cos_r - (y - 256) * scale * sin_r,
             cy + (x - 256) * scale * sin_r + (y - 256) * scale * cos_r)
            for x, y in points]


def stroke(d, points, width, fill):
    d.line(points, fill=fill, width=int(width), joint="curve")
    for p in (points[0], points[-1]):  # round caps
        d.ellipse([p[0] - width / 2, p[1] - width / 2,
                   p[0] + width / 2, p[1] + width / 2], fill=fill)


def render_master():
    img = Image.new("RGBA", (W, W), PAPER + (255,))
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, W, int(W * BAND_H)], fill=BRAND)

    lw = W * LINE_WIDTH
    for i in range(LINE_COUNT):
        y = W * (LINE_TOP + i * LINE_GAP)
        stroke(d, [(W * LINE_X0, y), (W * LINE_X1, y)], lw, RULE)

    # GroundWork's leaf, stamped on the lower right of the page. Green on pale
    # ruling, so it needs no gap cut around it to stay legible.
    outline = (cubic((256, 84), (368, 150), (368, 362), (256, 428))
               + cubic((256, 428), (144, 362), (144, 150), (256, 84)))
    scale = W * LEAF_SCALE
    cx, cy = W * LEAF_X, W * LEAF_Y
    d.polygon(place(outline, scale, cx, cy, LEAF_ANGLE), fill=BRAND)
    stroke(d, place([(256, 112), (256, 404)], scale, cx, cy, LEAF_ANGLE),
           max(1, int(24 * scale)), VEIN)

    return img.resize((SIZE, SIZE), Image.LANCZOS)


# ---------------------------------------------------------------- asset catalog

MAC = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
       (256, 1), (256, 2), (512, 1), (512, 2)]


def write_appiconset(master, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    images = []

    def emit(pixels, name):
        master.resize((pixels, pixels), Image.LANCZOS).convert("RGB").save(
            os.path.join(out_dir, name))

    emit(1024, "icon-ios-1024.png")
    images.append({"filename": "icon-ios-1024.png", "idiom": "universal",
                   "platform": "ios", "size": "1024x1024"})

    for pt, scale in MAC:
        name = f"icon-mac-{pt}x{pt}@{scale}x.png"
        emit(pt * scale, name)
        images.append({"filename": name, "idiom": "mac",
                       "scale": f"{scale}x", "size": f"{pt}x{pt}"})

    with open(os.path.join(out_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    import sys
    default = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "Sources", "NotesVaultApp", "Resources", "Assets.xcassets",
                           "AppIcon.appiconset")
    out = sys.argv[1] if len(sys.argv) > 1 else default
    write_appiconset(render_master(), out)
    print("wrote", out)
