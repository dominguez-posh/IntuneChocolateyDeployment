"""Showcase compositor for the README media (called by Tests\\Render-Showcase.ps1).

Requirements (no admin rights needed): Python 3.12, `pip install --user Pillow numpy`; optional `imageio-ffmpeg`
(bundled ffmpeg, only for demo.mp4); img2webp from libwebp (winget install Google.Libwebp) for the animated WebP;
oxipng (winget install Shssoichiro.Oxipng) for smaller PNGs.

Modes
  video  raw frames + frames.json of Tests\\DemoDriver.ps1  ->  demo.webp (+ demo.mp4)
  shots  raw PNGs of Tests\\DocsDriver.ps1                  ->  framed PNGs + hero.png

Look: the whole app window floats on a light soft stage (rounded corners, one deep soft shadow). In the video a
critically damped camera zooms to the element that is clicked and back out between scenes, content changes
crossfade, pointer, click ring and captions are drawn crisp on top, and a title and an end card frame the tour.
"""
import argparse
import bisect
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ACCENT = (0, 95, 184)
INK = (27, 27, 27)
MUTED = (88, 98, 112)
WINDOW_BG = (243, 243, 243)
SHADOW_RGB = (16, 30, 50)
FONT_DIR = r'C:\Windows\Fonts'


def font(name, size):
    for n in (name, 'segoeui.ttf', 'arial.ttf'):
        try:
            return ImageFont.truetype(os.path.join(FONT_DIR, n), size)
        except OSError:
            pass
    return ImageFont.load_default()


def clamp01(x):
    return min(max(x, 0.0), 1.0)


def smooth(x):
    x = clamp01(x)
    return x * x * (3 - 2 * x)


def ease_out(x):
    return 1 - (1 - clamp01(x)) ** 3


# ----------------------------------------------------------------------------------------------- stage

def make_bg(w, h):
    """Light soft stage: faint diagonal gradient plus two very subtle accent glows."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = (x / w * 0.45 + y / h * 0.55)[..., None]
    c0 = np.array([236, 241, 247], np.float32)
    c1 = np.array([248, 250, 253], np.float32)
    img = c0 + (c1 - c0) * t
    acc = np.array(ACCENT, np.float32)
    for cx, cy, r, a in ((0.88, 0.08, 0.50, 0.10), (0.06, 1.0, 0.45, 0.07)):
        d = np.sqrt(((x / w - cx) * w) ** 2 + ((y / h - cy) * w) ** 2) / (r * w)
        g = (np.exp(-d * d * 2.2) * a)[..., None]
        img = img * (1 - g) + acc * g
    return Image.fromarray(np.clip(img + 0.5, 0, 255).astype(np.uint8), 'RGB').convert('RGBA')


def flatten_window(path_or_img):
    """Paint the window background first: transparent regions of the WPF render become #F3F3F3, never black."""
    im = Image.open(path_or_img) if isinstance(path_or_img, str) else path_or_img
    im = im.convert('RGBA')
    base = Image.new('RGBA', im.size, WINDOW_BG + (255,))
    return Image.alpha_composite(base, im).convert('RGB')


_mask_cache = {}


def rounded_window(rgb, size, radius):
    """Window image scaled to size with antialiased rounded corners and a hairline border."""
    key = (size, radius)
    if key not in _mask_cache:
        ss = 4
        m = Image.new('L', (size[0] * ss, size[1] * ss), 0)
        ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] * ss - 1, size[1] * ss - 1), radius * ss, fill=255)
        m = m.resize(size, Image.LANCZOS)
        b = Image.new('RGBA', (size[0] * ss, size[1] * ss), (0, 0, 0, 0))
        ImageDraw.Draw(b).rounded_rectangle((0, 0, size[0] * ss - 1, size[1] * ss - 1), radius * ss,
                                            outline=(15, 30, 50, 46), width=max(1, ss))
        _mask_cache[key] = (m, b.resize(size, Image.LANCZOS))
    m, border = _mask_cache[key]
    w = rgb.resize(size, Image.LANCZOS).convert('RGBA')
    w.putalpha(m)
    return Image.alpha_composite(w, border)


def shadow_layer(size, rect, radius, scale=1.0):
    """One deep soft shadow plus a tight contact shadow."""
    out = Image.new('RGBA', size, (0, 0, 0, 0))
    x0, y0, x1, y1 = rect
    for blur, dy, alpha, spread in ((46, 34, 0.30, -6), (14, 8, 0.16, -1)):
        m = Image.new('L', size, 0)
        ImageDraw.Draw(m).rounded_rectangle(
            (x0 - spread * scale, y0 - spread * scale + dy * scale, x1 + spread * scale, y1 + spread * scale + dy * scale),
            radius + spread * scale, fill=int(255 * alpha))
        m = m.filter(ImageFilter.GaussianBlur(blur * scale))
        layer = Image.new('RGBA', size, SHADOW_RGB + (0,))
        layer.putalpha(m)
        out = Image.alpha_composite(out, layer)
    return out


def fit_scale(win_size, canvas, mx=0.07, my=0.085):
    return min(canvas[0] * (1 - 2 * mx) / win_size[0], canvas[1] * (1 - 2 * my) / win_size[1])


def center_rect(win_size, canvas, f):
    w, h = round(win_size[0] * f), round(win_size[1] * f)
    return ((canvas[0] - w) // 2, (canvas[1] - h) // 2, w, h)


# ----------------------------------------------------------------------------------------------- shots

def compose_window(canvas_img, rgb, x, y, w, h, radius, shadow_scale=1.0):
    sh = shadow_layer(canvas_img.size, (x, y, x + w, y + h), radius, shadow_scale)
    canvas_img.alpha_composite(sh)
    canvas_img.alpha_composite(rounded_window(rgb, (w, h), radius), (x, y))


def frame_shot(rgb, canvas=(1440, 900)):
    img = make_bg(*canvas)
    f = fit_scale(rgb.size, canvas)
    x, y, w, h = center_rect(rgb.size, canvas, f)
    compose_window(img, rgb, x, y, w, h, 12)
    return img.convert('RGB')


def hero_shot(wins, canvas=(1600, 900)):
    """Three whole windows layered: status behind, apps in the middle, the deploy dialog in front."""
    img = make_bg(*canvas)
    cw, ch = canvas
    ww = 940
    for rgb, x, y, wd in ((wins['status'], cw - ww - 70, 44, ww - 40), (wins['apps'], 60, 138, ww),
                          (wins['deploy'], 470, 318, ww)):
        h = round(wd * rgb.size[1] / rgb.size[0])
        compose_window(img, rgb, x, y, wd, h, 12, 0.8)
    return img.convert('RGB')


def save_png(img, path, oxipng):
    # Smooth gradients keep PNGs small; fall back to a 256 color palette only when a file stays above the limit
    img.save(path, optimize=True)
    if oxipng:
        subprocess.run([oxipng, '-o', '4', '--strip', 'safe', '-q', path], check=False)
    if os.path.getsize(path) > 380_000:
        q = img.quantize(256, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG)
        q.save(path, optimize=True)
        if oxipng:
            subprocess.run([oxipng, '-o', '4', '--strip', 'safe', '-q', path], check=False)


def run_shots(a):
    names = ('start', 'apps', 'deploy', 'tenant', 'schedule', 'status', 'import', 'activity', 'settings')
    os.makedirs(a.out, exist_ok=True)
    wins = {}
    for n in names:
        p = os.path.join(a.src, n + '.png')
        if not os.path.exists(p):
            print('warning: %s.png missing' % n)
            continue
        wins[n] = flatten_window(p)
        save_png(frame_shot(wins[n]), os.path.join(a.out, n + '.png'), a.oxipng)
    if all(k in wins for k in ('apps', 'deploy', 'status')):
        save_png(hero_shot(wins), os.path.join(a.out, 'hero.png'), a.oxipng)
    for n in names + ('hero',):
        p = os.path.join(a.out, n + '.png')
        if os.path.exists(p):
            print('%-9s %4d KB' % (n, os.path.getsize(p) // 1024))


# ----------------------------------------------------------------------------------------------- video

def persp_coeffs(dst, src):
    A, B = [], []
    for (x, y), (X, Y) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -X * x, -X * y]); B.append(X)
        A.append([0, 0, 0, x, y, 1, -Y * x, -Y * y]); B.append(Y)
    return np.linalg.solve(np.array(A, float), np.array(B, float)).tolist()


def tilt_warp(layer, p):
    """Window recedes with a slight perspective tilt (p=0 flat, p=1 tilted back and smaller)."""
    if p <= 0.0005:
        return layer
    w, h = layer.size
    sc = 1 - 0.09 * p
    cy = h / 2 + 0.07 * h * p
    hl, hr = h / 2 * sc * (1 + 0.04 * p), h / 2 * sc * (1 - 0.06 * p)
    xl, xr = w / 2 - w / 2 * sc * 1.01, w / 2 + w / 2 * sc * 0.95
    dst = [(xl, cy - hl), (xr, cy - hr), (xr, cy + hr), (xl, cy + hl)]
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    out = layer.transform((w, h), Image.PERSPECTIVE, persp_coeffs(dst, src), Image.BICUBIC)
    a = out.getchannel('A').point(lambda v: int(v * clamp01(1.25 - 1.25 * p)))
    out.putalpha(a)
    return out


def draw_logo(img, cx, cy, size):
    ss = 4
    s = size * ss
    t = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(t)
    d.rounded_rectangle((0, 0, s - 1, s - 1), s * 0.24, fill=ACCENT + (255,))
    k = s / 100.0
    w = (255, 255, 255, 255)
    d.rounded_rectangle((24 * k, 27 * k, 76 * k, 42 * k), 4 * k, outline=w, width=int(5 * k))
    d.rounded_rectangle((29 * k, 42 * k, 71 * k, 74 * k), 4 * k, outline=w, width=int(5 * k))
    d.line((43 * k, 54 * k, 57 * k, 54 * k), fill=w, width=int(5 * k))
    t = t.resize((size, size), Image.LANCZOS)
    img.alpha_composite(t, (int(cx - size / 2), int(cy - size / 2)))


def draw_centered(img, text, fnt, y, fill, alpha, dy=0):
    if alpha <= 0.002:
        return
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    wdt = d.textlength(text, font=fnt)
    d.text(((img.size[0] - wdt) / 2, y + dy), text, font=fnt, fill=fill + (int(255 * clamp01(alpha)),))
    img.alpha_composite(layer)


class Card:
    """Title and end card: logo, product name, subtitle, optional line."""

    def __init__(self, size, title, subtitle, line):
        self.size, self.title, self.subtitle, self.line = size, title, subtitle, line
        s = size[1] / 900.0
        self.f1, self.f2, self.f3 = font('seguisb.ttf', round(104 * s)), font('segoeui.ttf', round(36 * s)), font('segoeui.ttf', round(24 * s))
        self.s = s

    def draw(self, img, a, rise=0.0, line_alpha=None):
        """a: 0..1 overall; rise: 0 settled, 1 fully offset (slides up while it leaves, comes from below on entry)."""
        w, h = self.size
        s = self.s
        dy = 26 * s * rise
        la = a if line_alpha is None else line_alpha
        if a > 0.002:
            lg = Image.new('RGBA', img.size, (0, 0, 0, 0))
            draw_logo(lg, w / 2, h * 0.30 + dy, round(84 * s))
            lg.putalpha(lg.getchannel('A').point(lambda v: int(v * clamp01(a))))
            img.alpha_composite(lg)
        draw_centered(img, self.title, self.f1, h * 0.40, INK, a, dy)
        draw_centered(img, self.subtitle, self.f2, h * 0.40 + 150 * s, MUTED, a, dy)
        if self.line:
            draw_centered(img, self.line, self.f3, h * 0.40 + 232 * s, (120, 130, 144), la, dy)


def draw_pointer(img, x, y, s):
    """Crisp arrow with soft shadow, subpixel positioned (4x supersampled)."""
    ss = 4
    pad = 6
    ox, oy = math.floor(x) - pad, math.floor(y) - pad
    n = int(34 * s) + pad * 2
    pts = [(0, 0), (0, 18), (4.6, 13.8), (7.8, 21), (10.6, 19.8), (7.6, 12.8), (13.4, 12.8)]
    px = [((x - ox + qx * s) * ss, (y - oy + qy * s) * ss) for qx, qy in pts]
    sh = Image.new('L', (n * ss, n * ss), 0)
    ImageDraw.Draw(sh).polygon([(a + 1.2 * s * ss, b + 2.4 * s * ss) for a, b in px], fill=105)
    sh = sh.filter(ImageFilter.GaussianBlur(2.2 * s * ss))
    tile = Image.new('RGBA', (n * ss, n * ss), SHADOW_RGB + (0,))
    tile.putalpha(sh)
    d = ImageDraw.Draw(tile)
    d.polygon(px, fill=(255, 255, 255, 255))
    ins = 1.5 * s * ss
    cx = sum(p[0] for p in px) / len(px)
    cy = sum(p[1] for p in px) / len(px)
    inner = [(cx + (a - cx) * 0.80 + (px[0][0] - cx) * 0.0, cy + (b - cy) * 0.80) for a, b in px]
    # keep the tip on its point: shift the shrunk arrow so the tip coincides
    dx, dy = px[0][0] - inner[0][0] + ins * 0.55, px[0][1] - inner[0][1] + ins * 0.9
    d.polygon([(a + dx, b + dy) for a, b in inner], fill=(20, 20, 24, 255))
    tile = tile.resize((n, n), Image.LANCZOS)
    img.alpha_composite(tile, (ox, oy))


def draw_ring(img, x, y, age, s):
    if not (0 <= age < 0.55):
        return
    k = ease_out(age / 0.55)
    r = (10 + 40 * k) * s
    ss = 3
    n = int(r * 2 + 8)
    t = Image.new('RGBA', (n * ss, n * ss), (0, 0, 0, 0))
    ox, oy = math.floor(x - n / 2), math.floor(y - n / 2)
    cx, cy = (x - ox) * ss, (y - oy) * ss
    a = int(120 * (1 - k))
    ImageDraw.Draw(t).ellipse((cx - r * ss, cy - r * ss, cx + r * ss, cy + r * ss), fill=ACCENT + (a,),
                              outline=ACCENT + (min(255, a * 2),), width=int(2 * ss))
    img.alpha_composite(t.resize((n, n), Image.LANCZOS), (ox, oy))


def draw_caption(img, num, text, alpha, rise=0.0):
    if alpha <= 0.01 or not text:
        return
    w, h = img.size
    s = h / 900.0
    fnt = font('seguisb.ttf', round(21 * s))
    ss = 2
    d0 = ImageDraw.Draw(Image.new('L', (1, 1)))
    tw = d0.textlength(text, font=fnt)
    ph, badge = round(46 * s), round(26 * s)
    pw = int(tw + (badge + 34 * s if num else 36 * s) + 22 * s)
    t = Image.new('RGBA', (pw * ss, ph * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(t)
    d.rounded_rectangle((0, 0, pw * ss - 1, ph * ss - 1), ph * ss / 2, fill=(17, 24, 39, 240))
    x = 18 * s
    if num:
        d.ellipse((x * ss, (ph - badge) / 2 * ss, (x + badge) * ss, (ph + badge) / 2 * ss), fill=(76, 194, 255, 255))
        nf = font('segoeuib.ttf', round(15 * s) * ss)
        nw = d.textlength(num, font=nf)
        d.text(((x + badge / 2) * ss - nw / 2, ph / 2 * ss), num, font=nf, fill=(0, 36, 61, 255), anchor='lm')
        x += badge + 12 * s
    d.text((x * ss, ph / 2 * ss), text, font=font('seguisb.ttf', round(21 * s) * ss), fill=(255, 255, 255, 255), anchor='lm')
    t = t.resize((pw, ph), Image.LANCZOS)
    t.putalpha(t.getchannel('A').point(lambda v: int(v * clamp01(alpha))))
    img.alpha_composite(t, (int((w - pw) / 2), int(h - 76 * s + (1 - clamp01(alpha)) * 10 * s + rise)))


def load_frames(frames_dir):
    raw = json.load(open(os.path.join(frames_dir, 'frames.json'), encoding='utf-8-sig'))
    if isinstance(raw, dict):
        raw = [raw]
    return raw


def run_video(a):
    if a.part is None:
        return run_video_parent(a)
    CW, CH = a.width, a.height
    K = 1.5
    WW, WH = round(CW * K), round(CH * K)
    fps = a.fps
    frames = load_frames(a.frames)
    n = len(frames)
    dur = [max(0.04, float(f['ms']) / 1000.0) * a.stretch for f in frames]
    dur[-1] = 1.5
    if a.tour_seconds and sum(dur) > a.tour_seconds:  # fast forward the recorded tour to the target length
        k = (a.tour_seconds - 1.5) / (sum(dur) - 1.5)
        dur = [d * k for d in dur[:-1]] + [1.5]
    T = [0.0]
    for d in dur[:-1]:
        T.append(T[-1] + d)
    tour_len = T[-1] + dur[-1]

    first = Image.open(os.path.join(a.frames, frames[0]['file']))
    src_w, src_h = first.size
    f = fit_scale(first.size, (CW, CH))
    wx, wy, ww, wh = center_rect(first.size, (WW, WH), f * K)
    radius = round(12 * K)
    win_scale = ww / src_w
    shadow_world = shadow_layer((WW, WH), (wx, wy, wx + ww, wy + wh), radius, K)
    bg_big = make_bg(round(CW * 1.3), round(CH * 1.3))

    cache = {}

    def src_frame(i):
        i = min(max(i, 0), n - 1)
        if i not in cache:
            if len(cache) > 12:
                cache.pop(next(iter(cache)))
            cache[i] = flatten_window(os.path.join(a.frames, frames[i]['file']))
        return cache[i]

    # Content changes big enough to deserve a crossfade (page or dialog change)
    thumbs = [np.asarray(src_frame(i).resize((96, 58), Image.BILINEAR), np.float32) for i in range(n)]
    big = [False] * n
    for i in range(1, n):
        big[i] = float(np.abs(thumbs[i] - thumbs[i - 1]).mean()) > 3.2
    cache.clear()
    XF = 0.34

    def content_at(tt):
        idx = min(max(bisect.bisect_right(T, tt) - 1, 0), n - 1)
        for b in range(idx, max(idx - 6, 0), -1):
            if big[b] and tt - T[b] < XF:
                w = smooth((tt - T[b]) / XF)
                if w < 1:
                    return Image.blend(src_frame(b - 1), src_frame(idx), w)
                break
        return src_frame(idx)

    def lerp_pointer(tt):
        idx = min(max(bisect.bisect_right(T, tt) - 1, 0), n - 1)
        j = min(idx + 1, n - 1)
        span = T[j] - T[idx]
        k = clamp01((tt - T[idx]) / span) if span > 0 else 0
        return (frames[idx]['px'] * (1 - k) + frames[j]['px'] * k, frames[idx]['py'] * (1 - k) + frames[j]['py'] * k)

    # Timeline: title card, window entrance, tour, outro, end card
    t_enter0, t_enter1 = 2.7, 4.8
    t0 = t_enter1
    t_tour_end = t0 + tour_len
    t_out0 = t_tour_end + 0.5
    t_out1 = t_out0 + 1.1
    t_end = t_out1 + 3.6
    N = int(t_end * fps)

    # Focus (window pixel rect) and scene boundaries over tour time
    def focus_at(tt):
        idx = min(max(bisect.bisect_right(T, tt) - 1, 0), n - 1)
        for k in range(idx, -1, -1):
            fr = frames[k]
            if fr.get('fw') is not None:
                if k == idx or tt - T[k + 1] < 1.4:
                    return (fr['fx'], fr['fy'], fr['fw'], fr['fh'])
                return None
            if tt - T[k] > 1.4 and k < idx:
                return None
        return None

    scene_start = {}
    for i, fr in enumerate(frames):
        s = fr.get('scene') or 0
        if s and s not in scene_start:
            scene_start[s] = T[i]

    def cam_target(t):
        cx0, cy0 = WW / 2, WH / 2
        if t < t0 or t > t_tour_end:
            return cx0, cy0, 1.0
        tt = t - t0
        for st in scene_start.values():
            if 0 <= tt - st < 1.0:
                return cx0, cy0, 1.0
        fo = focus_at(tt)
        if not fo:
            return cx0, cy0, 1.0
        fx, fy, fw_, fh_ = fo
        z = 1.42 if max(fw_, fh_) < 520 else 1.26
        wxc = wx + (fx + fw_ / 2) * win_scale
        wyc = wy + (fy + fh_ / 2) * win_scale
        return wxc, wyc, z

    def clamp_cam(cx, cy, z):
        bw, bh = WW / z, WH / z
        pad = 0.035 * WW
        lo, hi = wx - pad, wx + ww + pad - bw
        x0 = (lo + hi) / 2 if lo > hi else min(max(cx - bw / 2, lo), hi)
        lo, hi = wy - pad, wy + wh + pad - bh
        y0 = (lo + hi) / 2 if lo > hi else min(max(cy - bh / 2, lo), hi)
        return min(max(x0, 0.0), WW - bw), min(max(y0, 0.0), WH - bh), bw, bh

    # Critically damped (two cascaded low passes) camera: eased starts and stops, no overshoot
    cam = []
    s1 = list(cam_target(0)[:2]) + [0.0]
    s2 = list(s1)
    dt = 1.0 / fps
    k1 = 1 - math.exp(-dt * 4.2)
    for i in range(N):
        tx, ty, tz = cam_target(i * dt)
        tgt = [tx, ty, math.log(tz)]
        for q in range(3):
            s1[q] += (tgt[q] - s1[q]) * k1
            s2[q] += (s1[q] - s2[q]) * k1
        cam.append((s2[0], s2[1], math.exp(s2[2])))

    # Captions as segments
    segs = []
    for i, fr in enumerate(frames):
        c = fr.get('caption') or ''
        if c and (not segs or segs[-1]['text'] != c or segs[-1]['end'] is not None):
            segs.append({'text': c, 'num': fr.get('captionNumber') or '', 'start': T[i], 'end': None})
        elif not c and segs and segs[-1]['end'] is None:
            segs[-1]['end'] = T[i]
    for sg in segs:
        if sg['end'] is None:
            sg['end'] = tour_len

    def caption_state(tt):
        for sg in segs:
            if sg['start'] - 0.01 <= tt <= sg['end'] + 0.3:
                a_in = smooth((tt - sg['start']) / 0.35)
                a_out = 1 - smooth((tt - sg['end']) / 0.3)
                return sg['num'], sg['text'], min(a_in, a_out)
        return '', '', 0.0

    click_times = [T[i] for i in range(n) if frames[i].get('ring') == 0]

    card = Card((CW, CH), a.title, a.subtitle, a.url)

    tmp = a.workdir
    hashes = open(os.path.join(tmp, 'hashes_%d.txt' % a.part), 'w')
    for i in range(a.part, N, a.parts):
        t = i * dt
        cx, cy, z = cam[i]
        x0, y0, bw, bh = clamp_cam(cx, cy, z)
        # background: slow parallax, slightly settling during the entrance
        e_in = ease_out((t - t_enter0) / (t_enter1 - t_enter0))
        bz = (1 + (z - 1) * 0.30) * (1.0 + 0.05 * (1 - e_in))
        bw_ = CW * 1.3 / bz
        bh_ = CH * 1.3 / bz
        bcx = CW * 1.3 / 2 + ((x0 + bw / 2) - WW / 2) / K * 0.18
        bcy = CH * 1.3 / 2 + ((y0 + bh / 2) - WH / 2) / K * 0.18
        # the stage view shows CW x CH of the 1.3x background at zoom 1: crop the matching center
        vw, vh = CW / bz, CH / bz
        base = bg_big.resize((CW, CH), Image.BICUBIC, box=(bcx - vw / 2, bcy - vh / 2, bcx + vw / 2, bcy + vh / 2))
        canvas = base.copy()

        # window layer
        tp = 1.0
        show_win = t >= t_enter0 - 0.01 and t < t_out1 + 0.01
        p_tilt, a_win = 0.0, 1.0
        if t < t_enter1:
            p_tilt = 1 - ease_out((t - t_enter0) / (t_enter1 - t_enter0))
        if t >= t_out0:
            p_tilt = smooth((t - t_out0) / (t_out1 - t_out0))
        tour_t = min(max(t - t0, 0.0), tour_len - 0.001)
        if show_win:
            fgw = shadow_world.copy()
            fgw.alpha_composite(rounded_window(content_at(tour_t), (ww, wh), radius), (wx, wy))
            fgv = fgw.resize((CW, CH), Image.BICUBIC, box=(x0, y0, x0 + bw, y0 + bh))
            fgv = tilt_warp(fgv, p_tilt)
            canvas.alpha_composite(fgv)

        # overlays on the tour
        if t0 <= t <= t_tour_end + 0.3 and p_tilt < 0.001:
            sc = CW / bw  # world -> canvas
            px, py = lerp_pointer(tour_t)
            sx = (wx + px * win_scale - x0) * sc
            sy = (wy + py * win_scale - y0) * sc
            ps = f * z * 1.25
            for ct in click_times:
                draw_ring(canvas, sx, sy, tour_t - ct, ps * 1.0)
            draw_pointer(canvas, sx, sy, ps)
            num, text, al = caption_state(tour_t)
            draw_caption(canvas, num, text, al)

        # title and end cards
        if t < t_enter1 - 0.4:
            a_t = ease_out((t - 0.15) / 0.9) * (1 - smooth((t - 2.7) / 0.9))
            r_t = (1 - ease_out((t - 0.15) / 0.9)) + smooth((t - 2.7) / 0.9) * -1
            card.draw(canvas, a_t, r_t)
        if t > t_out0 + 0.2:
            a_e = ease_out((t - t_out0 - 0.2) / 1.0) * (1 - smooth((t - (t_end - 0.45)) / 0.45))
            card.draw(canvas, a_e, 1 - ease_out((t - t_out0 - 0.2) / 1.0))

        rgb = canvas.convert('RGB')
        rgb.save(os.path.join(tmp, 'o%05d.png' % i), compress_level=1)
        hashes.write('%d %s' %  (i, hashlib.md5(rgb.tobytes()).hexdigest()) + chr(10))
    hashes.close()
    print('part %d done' % a.part)


def video_length(a):
    return None


def run_video_parent(a):
    tmp = a.workdir or tempfile.mkdtemp(prefix='showcase_')
    os.makedirs(tmp, exist_ok=True)
    fps = a.fps
    if not a.encode_only:
        procs = []
        for k in range(a.parts):
            cmd = [sys.executable, os.path.abspath(__file__), 'video', '--frames', a.frames, '--out', a.out, '--img2webp', a.img2webp,
                   '--width', str(a.width), '--height', str(a.height), '--fps', str(fps), '--tour-seconds', str(a.tour_seconds),
                   '--title', a.title, '--subtitle', a.subtitle, '--url', a.url, '--part', str(k), '--parts', str(a.parts), '--workdir', tmp]
            procs.append(subprocess.Popen(cmd))
        for pr in procs:
            if pr.wait() != 0:
                raise SystemExit('render worker failed')
    order = {}
    for k in range(a.parts):
        for line in open(os.path.join(tmp, 'hashes_%d.txt' % k)):
            i, h = line.split()
            order[int(i)] = h
    N = len(order)
    ff = None
    if a.mp4:
        try:
            import imageio_ffmpeg
            exe = imageio_ffmpeg.get_ffmpeg_exe()
            ff = subprocess.Popen([exe, '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '%dx%d' % (a.width, a.height),
                                   '-r', str(fps), '-i', '-', '-c:v', 'libx264', '-preset', 'slow', '-crf', '20',
                                   '-pix_fmt', 'yuv420p', '-movflags', '+faststart', a.mp4], stdin=subprocess.PIPE)
        except Exception as e:  # no encoder available: skip the mp4
            print('mp4 skipped (%s)' % e)
    if ff:
        for i in range(N):
            ff.stdin.write(Image.open(os.path.join(tmp, 'o%05d.png' % i)).convert('RGB').tobytes())
    if ff:
        ff.stdin.close()
        ff.wait()
    # Animated WebP: every webp_step-th frame (the mp4 keeps the full rate), scaled to webp_width, identical neighbours merged
    wfps = fps / a.webp_step
    ww_ = a.webp_width
    wh_ = round(a.height * ww_ / a.width)
    out_frames, last = [], None  # [file, start_ms]
    for i in range(0, N, a.webp_step):
        if order[i] == last:
            continue
        last = order[i]
        name = 'w%05d.png' % i
        im = Image.open(os.path.join(tmp, 'o%05d.png' % i)).convert('RGB')
        if ww_ != a.width:
            im = im.resize((ww_, wh_), Image.LANCZOS)
        im.save(os.path.join(tmp, name), compress_level=1)
        out_frames.append([name, i * 1000.0 / fps])
    total_ms = N * 1000.0 / fps
    for k in range(len(out_frames)):
        end = out_frames[k + 1][1] if k + 1 < len(out_frames) else total_ms
        out_frames[k][1] = end - out_frames[k][1]
    args = [a.img2webp, '-loop', '0', '-lossy', '-q', str(a.quality), '-m', '4', '-exact', '-kmin', '3', '-kmax', '6']
    for name, ms in out_frames:
        args += ['-d', str(max(10, round(ms))), name]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    args += ['-o', os.path.abspath(a.out)]
    r = subprocess.run(args, cwd=tmp, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('img2webp failed: ' + r.stderr)
    if not a.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    print('Video: %d frames, %.0f fps (webp %d frames, %.0f fps), %.1f s, webp %.1f MB%s' % (
        N, fps, len(out_frames), wfps, N / fps, os.path.getsize(a.out) / 1048576,
        (', mp4 %.1f MB' % (os.path.getsize(a.mp4) / 1048576)) if ff and os.path.exists(a.mp4) else ''))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='mode', required=True)
    v = sub.add_parser('video')
    v.add_argument('--frames', required=True)
    v.add_argument('--out', required=True)
    v.add_argument('--mp4')
    v.add_argument('--img2webp', required=True)
    v.add_argument('--width', type=int, default=1440)
    v.add_argument('--height', type=int, default=900)
    v.add_argument('--fps', type=int, default=30)
    v.add_argument('--quality', type=int, default=35)
    v.add_argument('--webp-step', type=int, default=2)
    v.add_argument('--webp-width', type=int, default=1280)
    v.add_argument('--stretch', type=float, default=1.0)
    v.add_argument('--tour-seconds', type=float, default=40.0)
    v.add_argument('--part', type=int)
    v.add_argument('--parts', type=int, default=6)
    v.add_argument('--workdir')
    v.add_argument('--keep', action='store_true')
    v.add_argument('--encode-only', action='store_true')
    v.add_argument('--title', default='PackTune')
    v.add_argument('--subtitle', default='winget and Chocolatey apps for Intune')
    v.add_argument('--url', default='github.com/dominguez-posh/IntuneChocolateyDeployment')
    s = sub.add_parser('shots')
    s.add_argument('--src', required=True)
    s.add_argument('--out', required=True)
    s.add_argument('--oxipng')
    a = p.parse_args()
    run_video(a) if a.mode == 'video' else run_shots(a)


if __name__ == '__main__':
    main()
