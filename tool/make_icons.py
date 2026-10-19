"""Builds the NoteDo app icons from the logo mark.

    python tool/make_icons.py                  draw the mark (a stand-in for the real artwork) and build the icons
    python tool/make_icons.py logo.png         use this image instead (transparent PNG; the mark and, below it, the word)
    python tool/make_icons.py logo.png --box 380,130,570,330     crop to this box (x0,y0,x1,y1) of the image

With an image and no --box, the part above the wordmark is used: the script looks for the empty row between the
mark and the "NoteDo" text and keeps what is above it.

Writes assets/branding/notedo_mark.png (transparent, cropped tight), the Android launcher icons (adaptive,
legacy and the single-colour one for themed icons) and windows/runner/resources/app_icon.ico.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')


# ------------------------------------------------------------------ the stand-in drawing
def arc(cx, cy, r, a0, a1, n=24):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def draw_mark(size=1024):
    """The note with a check and a pen, in neon strokes with a soft glow, on a transparent background."""
    ss = 3  # supersampling
    S = size * ss
    u = S * 0.62 / 100.0  # one unit of the 0..100 drawing
    ox = oy = (S - 100 * u) / 2

    def P(pts):
        return [(ox + x * u, oy + y * u) for x, y in pts]

    def stroke(mask, pts, width):
        d = ImageDraw.Draw(mask)
        w = width * u
        d.line(P(pts), fill=255, width=int(w), joint='curve')
        for x, y in P([pts[0], pts[-1]]):
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)

    note = Image.new('L', (S, S), 0)
    check = Image.new('L', (S, S), 0)
    pen = Image.new('L', (S, S), 0)
    side = Image.new('L', (S, S), 0)

    r = 12
    outline = [(44, 4), (4 + r, 4)] + arc(4 + r, 4 + r, r, 270, 180) + [(4, 84)] + arc(4 + r, 84, r, 180, 90) + [(60, 96)] + arc(60, 84, r, 90, 0) + [(72, 62)]
    stroke(note, outline, 5.2)
    stroke(check, [(20, 47), (34, 60), (58, 30)], 5.2)

    ax, ay, tx, ty = 84.0, 12.0, 20.0, 90.0
    L = math.hypot(tx - ax, ty - ay)
    dx, dy = (tx - ax) / L, (ty - ay) / L
    nx, ny = -dy, dx
    w = 9.0
    bx, by = ax + (tx - ax) * 0.78, ay + (ty - ay) * 0.78

    def round_end(radius, s0=0.0, s1=math.pi, n=18):
        """Points round the far end of the pen (away from the tip), from one side to the other."""
        return [(ax + radius * (-math.cos(s) * nx - math.sin(s) * dx), ay + radius * (-math.cos(s) * ny - math.sin(s) * dy))
                for s in [s0 + (s1 - s0) * i / n for i in range(n + 1)]]

    body = [(ax + nx * w, ay + ny * w), (bx + nx * w, by + ny * w), (tx, ty), (bx - nx * w, by - ny * w), (ax - nx * w, ay - ny * w)] + round_end(w)
    stroke(pen, body, 5.0)
    # the band near the top of the pen
    k = 0.2
    stroke(pen, [(ax + (tx - ax) * k + nx * w, ay + (ty - ay) * k + ny * w), (ax + (tx - ax) * k - nx * w, ay + (ty - ay) * k - ny * w)], 4.0)
    # a second, offset outline on the right: the pen's clip
    clip = round_end(w + 8, math.pi * 0.62, math.pi, 10)
    last = clip[-1]
    stroke(side, clip + [(last[0] + dx * 22, last[1] + dy * 22)], 4.4)

    yy, xx = np.mgrid[0:S, 0:S]
    t = np.clip(((xx - ox) + (yy - oy)) / (200 * u), 0, 1)  # 0 top-left .. 1 bottom-right

    def lerp(a, b, f):
        return np.array(a)[None, None, :] * (1 - f[..., None]) + np.array(b)[None, None, :] * f[..., None]

    cyan, blue, violet, mint = (53, 213, 245), (84, 140, 247), (139, 92, 246), (46, 230, 190)
    base = np.where((t < 0.5)[..., None], lerp(cyan, blue, np.clip(t * 2, 0, 1)), lerp(blue, violet, np.clip(t * 2 - 1, 0, 1)))
    mint_to_cyan = lerp(mint, cyan, np.clip(t * 2, 0, 1))
    violet_flat = np.broadcast_to(np.array((150, 100, 246), dtype=float), base.shape)

    layers = [(note, base), (pen, base), (check, mint_to_cyan), (side, violet_flat)]
    rgb = np.zeros((S, S, 3))
    alpha = np.zeros((S, S))
    for mask, colour in layers:
        a = np.asarray(mask, dtype=float) / 255.0
        rgb = rgb * (1 - a[..., None]) + colour * a[..., None]
        alpha = np.maximum(alpha, a)

    glow = Image.fromarray((alpha * 255).astype('uint8')).filter(ImageFilter.GaussianBlur(S * 0.012))
    glow_a = np.asarray(glow, dtype=float) / 255.0 * 0.55
    out_a = np.clip(alpha + glow_a * (1 - alpha), 0, 1)
    out_rgb = np.where(out_a[..., None] > 0, (rgb * alpha[..., None] + rgb_glow(rgb, alpha, S) * (glow_a * (1 - alpha))[..., None]) / np.maximum(out_a[..., None], 1e-6), 0)
    img = Image.fromarray(np.dstack([np.clip(out_rgb, 0, 255), out_a * 255]).astype('uint8'), 'RGBA')
    return img.resize((size, size), Image.LANCZOS)


def rgb_glow(rgb, alpha, S):
    """The glow takes the colour of the nearest stroke: blur the colour, weighted by the stroke."""
    weighted = Image.fromarray(np.clip(rgb * alpha[..., None], 0, 255).astype('uint8'), 'RGB').filter(ImageFilter.GaussianBlur(S * 0.012))
    weight = Image.fromarray((alpha * 255).astype('uint8')).filter(ImageFilter.GaussianBlur(S * 0.012))
    w = np.asarray(weight, dtype=float)[..., None] / 255.0
    return np.where(w > 1e-4, np.asarray(weighted, dtype=float) / np.maximum(w, 1e-4), 0)


# ------------------------------------------------------------------ taking a supplied image
def load_mark(path, box=None):
    im = Image.open(path).convert('RGBA')
    if box:
        im = im.crop(box)
    else:
        a = np.asarray(im)[..., 3] > 24
        rows = np.where(a.any(axis=1))[0]
        # the first empty band of rows after the mark separates it from the wordmark
        top, prev, cut = rows[0], rows[0], None
        for r in rows[1:]:
            if r - prev > max(6, int(0.02 * im.height)):
                cut = prev
                break
            prev = r
        im = im.crop((0, top, im.width, (cut if cut is not None else rows[-1]) + 1))
    a = np.asarray(im)[..., 3] > 8
    ys, xs = np.where(a)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def on_canvas(mark, canvas, fraction):
    """The mark centred on a transparent square canvas, its longer side [fraction] of the canvas."""
    scale = canvas * fraction / max(mark.size)
    m = mark.resize((max(1, round(mark.width * scale)), max(1, round(mark.height * scale))), Image.LANCZOS)
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    out.alpha_composite(m, ((canvas - m.width) // 2, (canvas - m.height) // 2))
    return out


def white_only(img):
    """Single colour (white) with the same shape: for Android's themed icons."""
    a = np.asarray(img)[..., 3]
    out = np.zeros(a.shape + (4,), dtype='uint8')
    out[..., :3] = 255
    out[..., 3] = (np.clip(a.astype(float) * 1.6, 0, 255)).astype('uint8')
    return Image.fromarray(out, 'RGBA')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    box = None
    for i, a in enumerate(sys.argv):
        if a == '--box':
            box = tuple(int(v) for v in sys.argv[i + 1].split(','))
            args = [x for x in args if x != sys.argv[i + 1]]
    if args:
        mark = load_mark(args[0], box)
        print('using', args[0], 'cropped to', mark.size)
    else:
        mark = draw_mark(1024)
        a = np.asarray(mark)[..., 3] > 8
        ys, xs = np.where(a)
        mark = mark.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
        print('drew the stand-in mark', mark.size)

    os.makedirs(os.path.join(ROOT, 'assets', 'branding'), exist_ok=True)
    full = on_canvas(mark, 1024, 0.84)
    full.save(os.path.join(ROOT, 'assets', 'branding', 'notedo_mark.png'))

    densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for name, k in densities.items():
        d = os.path.join(RES, f'mipmap-{name}')
        os.makedirs(d, exist_ok=True)
        fg = on_canvas(mark, round(108 * k), 0.50)  # the adaptive icon's safe zone is the middle 66 of 108
        fg.save(os.path.join(d, 'ic_launcher_foreground.png'))
        white_only(fg).save(os.path.join(d, 'ic_launcher_monochrome.png'))
        on_canvas(mark, round(48 * k), 0.84).save(os.path.join(d, 'ic_launcher.png'))  # Android 7.x and older
    anydpi = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    open(os.path.join(anydpi, 'ic_launcher.xml'), 'w', newline='\n').write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''')
    colors = os.path.join(RES, 'values', 'colors.xml')
    s = open(colors, encoding='utf-8').read()
    if 'ic_launcher_background' not in s:
        s = s.replace('</resources>', '    <!-- The icon has no background tile: only the mark. -->\n    <color name="ic_launcher_background">#00000000</color>\n</resources>')
        open(colors, 'w', encoding='utf-8', newline='\n').write(s)

    ico = on_canvas(mark, 256, 0.9)
    ico.save(os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico'), format='ICO', sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)])
    print('icons written')


if __name__ == '__main__':
    main()
