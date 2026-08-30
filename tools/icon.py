"""GroundWork Notes app icon.

The same design language as GroundWork's own icon, with a notepad where the bar
chart was and the leaf doing the pencil's job.

Everything here is taken from the GroundWork icon rather than invented:

  * the vertical sage gradient, #6B8C7D to #405449, sampled from icon-512.png;
  * the foreground white, #FBFDFB, and the brand green #5C7A6D;
  * the middle bar's tint, #C2CCC6, reused for the ruled lines so the page's
    interior belongs to the same family;
  * the leaf outline, which is the exact Bezier from icon-ideas/A-leaf-refined.svg
    rather than a redrawing of it, kept in GroundWork's own treatment of a solid
    white body with a green midrib.

The page is drawn rather than filled, which is the one deliberate departure:
GroundWork's icon is solid and chunky, and this is lighter. The leaf stays solid
so it still carries weight when the strokes thin out at small sizes, and so it
remains recognisably GroundWork's leaf rather than a generic pointed oval.

Flat fills and strokes only — no shadows and no gradients on the foreground.
GroundWork's icon has none, and they are the first thing that would make this
look like a different app.

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
# Sampled from TherapyTracker-web/icon-512.png and A-leaf-refined.svg.

BG_TOP = (0x6B, 0x8C, 0x7D)
BG_BOTTOM = (0x40, 0x54, 0x49)
WHITE = (0xFB, 0xFD, 0xFB)      # the tall bar, and the leaf body
BRAND = (0x5C, 0x7A, 0x6D)      # the leaf's midrib
TINT = (0xC2, 0xCC, 0xC6)       # the middle bar, reused for the ruled lines

S = 8            # supersample factor
SIZE = 1024      # master size
W = SIZE * S

STROKE = W * 0.026               # the page outline
PAGE = dict(x0=0.180, y0=0.190, x1=0.615, y1=0.790, radius=0.050)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def background():
    """Vertical gradient. GroundWork's is top-lighter, bottom-darker."""
    img = Image.new("RGBA", (W, W), (0, 0, 0, 255))
    d = ImageDraw.Draw(img)
    for y in range(W):
        d.line([(0, y), (W, y)], fill=lerp(BG_TOP, BG_BOTTOM, y / W))
    return img


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


def stroke(d, points, width, fill, closed=False):
    pts = points + [points[0]] if closed else points
    d.line(pts, fill=fill, width=int(width), joint="curve")
    for p in (pts[0], pts[-1]):  # round caps
        d.ellipse([p[0] - width / 2, p[1] - width / 2,
                   p[0] + width / 2, p[1] + width / 2], fill=fill)


def page(img):
    """The pad, drawn as an outline. Sits where the bar chart used to."""
    d = ImageDraw.Draw(img)
    x0, y0 = int(W * PAGE["x0"]), int(W * PAGE["y0"])
    x1, y1 = int(W * PAGE["x1"]), int(W * PAGE["y1"])
    r = int(W * PAGE["radius"])

    d.rounded_rectangle([x0, y0, x1, y1], radius=r, outline=WHITE, width=int(STROKE))

    # Bound top edge: a rule across the page with three punched rings above it,
    # which is the detail that says "notepad" rather than "document".
    band_y = y0 + int((y1 - y0) * 0.155)
    d.line([(x0, band_y), (x1, band_y)], fill=WHITE, width=int(STROKE))
    ring_r = (band_y - y0) * 0.20
    for i in (1, 2, 3):
        cx = x0 + (x1 - x0) * i / 4
        cy = y0 + (band_y - y0) * 0.52
        d.ellipse([cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r], fill=WHITE)

    # Ruled lines, in the middle bar's tint so they sit behind the page outline
    # rather than competing with it. Lengths vary so it reads as writing.
    left = x0 + int((x1 - x0) * 0.145)
    usable = (x1 - x0) * 0.71
    top = band_y + int((y1 - y0) * 0.185)
    gap = int((y1 - y0) * 0.185)
    for i, frac in enumerate([1.00, 0.80, 0.55]):
        y = top + i * gap
        stroke(d, [(left, y), (left + usable * frac, y)], STROKE * 0.78, TINT)


def leaf_parts():
    """GroundWork's leaf, placed where a pen would rest on the page."""
    outline = (cubic((256, 84), (368, 150), (368, 362), (256, 428))
               + cubic((256, 428), (144, 362), (144, 150), (256, 84)))
    scale = W * 0.00120
    cx, cy = W * 0.665, W * 0.590
    angle = 40
    return (place(outline, scale, cx, cy, angle),
            place([(256, 112), (256, 404)], scale, cx, cy, angle),
            max(1, int(24 * scale)))


def render_master():
    bg = background()
    img = bg.copy()
    page(img)

    # The leaf crosses the page, and both are drawn in the same white. Without a
    # gap they fuse and the leaf stops reading as a leaf; GroundWork's own icon
    # keeps its shapes clearly apart. Paste the gradient back through a dilated
    # silhouette so the leaf reads as being in front.
    shape, rib, rib_w = leaf_parts()
    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(shape, fill=255)
    md.line(shape + [shape[0]], fill=255, width=int(W * 0.030), joint="curve")
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    d.polygon(shape, fill=WHITE)
    stroke(d, rib, rib_w, BRAND)

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
    master = render_master()
    write_appiconset(master, out)
    print("wrote", out)
