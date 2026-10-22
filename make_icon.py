#!/usr/bin/env python3
"""生成 NTFS 读写助手 App 图标 (AppIcon.icns) — v5 legacy 规范
   v4 教训：全出血方形 icns 会被 macOS 27 判为「未适配」，
   系统垫一层浅色玻璃底板并把内容缩进去（用户看到的白边/没铺满）。
   v5 改用 Big Sur 官方 legacy 规范：1024 画布 + 824×824 圆角方块（r≈185）
   + 四周 100px 透明边距，无描边无阴影 —— 系统原样渲染，不垫底板。
   同时输出网站可用的 logo PNG 与 favicon（全出血方形版）。"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE = 1024
TILE = 824          # 图标本体尺寸（Big Sur 规范）
MARGIN = (SIZE - TILE) // 2
RADIUS = 185        # 官方圆角半径（824 的 22.5%）
OUT = os.path.dirname(os.path.abspath(__file__))

def lerp(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))

def diag_grad(size, c1, c2):
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126.0
            px[x, y] = lerp(c1, c2, t)
    return small.resize((size, size), Image.BICUBIC).convert("RGBA")

def radial_glow(img, center, radius, color, max_alpha):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    steps = 24
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(max_alpha * (1 - i / steps) ** 1.6)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color + (a,))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(radius * 0.18)))

# ---- 在 824×824 的 tile 上作画（全出血设计） ----
S = TILE
tile = diag_grad(S, (47, 128, 255), (8, 32, 108))

radial_glow(tile, (200, 135), 500, (150, 205, 255), 95)
radial_glow(tile, (720, 760), 450, (3, 8, 50), 130)

band = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(band).polygon([(-100, 520), (430, -130), (700, -130), (-100, 730)],
                             fill=(255, 255, 255, 34))
tile.alpha_composite(band.filter(ImageFilter.GaussianBlur(40)))

def load_font(size, candidates):
    for c in candidates:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, size)
            except Exception:
                continue
    raise SystemExit("no font found: " + repr(candidates))

FONT_PATHS = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]
FONT_CN = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]

# ---- NTFS 大字：占 tile 宽约 76% ----
text = "NTFS"
target_w = int(S * 0.76)
fs = 260
while fs < 460:
    f = load_font(fs, FONT_PATHS)
    bb = ImageDraw.Draw(tile).textbbox((0, 0), text, font=f)
    if bb[2] - bb[0] >= target_w:
        break
    fs += 8
font_big = load_font(fs, FONT_PATHS)
bb = ImageDraw.Draw(tile).textbbox((0, 0), text, font=font_big)
tw, th = bb[2] - bb[0], bb[3] - bb[1]
tx = (S - tw) // 2 - bb[0]
ty = int(S * 0.42) - th // 2 - bb[1]

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).text((tx + 4, ty + 18), text, font=font_big, fill=(0, 16, 70, 160))
tile.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))

txt_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tmask = Image.new("L", (S, S), 0)
ImageDraw.Draw(tmask).text((tx, ty), text, font=font_big, fill=255)
grad = diag_grad(S, (255, 255, 255), (196, 224, 255))
txt_layer.paste(grad, (0, 0), tmask)
tile.alpha_composite(txt_layer)

# ---- 读写双向箭头 ----
def arrow(img, x1, x2, y, head, color):
    d = ImageDraw.Draw(img)
    d.line([x1, y, x2, y], fill=color, width=22)
    s = 1 if (x2 > x1) else -1
    d.polygon([(x2 + s * head, y), (x2 - s * 8, y - head - 6),
               (x2 - s * 8, y + head + 6)], fill=color)

arrows = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mid = S // 2
arrow(arrows, mid - 140, mid + 116, int(S * 0.60), 34, (255, 255, 255, 240))
arrow(arrows, mid + 140, mid - 116, int(S * 0.71), 34, (255, 255, 255, 200))
tile.alpha_composite(arrows)

font_cn = load_font(48, FONT_CN)
t2 = "读写助手"
b2 = ImageDraw.Draw(tile).textbbox((0, 0), t2, font=font_cn)
tw2 = b2[2] - b2[0]
ImageDraw.Draw(tile).text(((S - tw2) // 2 - b2[0], int(S * 0.855) - (b2[3] - b2[1]) // 2 - b2[1]),
                          t2, font=font_cn, fill=(255, 255, 255, 235))

# ---- 组装：1024 透明画布 + 圆角 tile 居中 ----
canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
mask = Image.new("L", (TILE, TILE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, TILE, TILE], RADIUS, fill=255)
canvas.paste(tile, (MARGIN, MARGIN), mask)

# ---- 质检 ----
px = canvas.load()
corner_bad = sum(1 for (x, y) in [(0, 0), (SIZE-1, 0), (0, SIZE-1), (SIZE-1, SIZE-1)] if px[x, y][3] != 0)
# tile 边缘必须完全不透明（防系统误判）
edge_bad = 0
for i in range(0, TILE, 4):
    for (x, y) in [(MARGIN + i, MARGIN), (MARGIN + i, MARGIN + TILE - 1),
                   (MARGIN, MARGIN + i), (MARGIN + TILE - 1, MARGIN + i)]:
        if px[x, y][3] < 255:
            edge_bad += 1
print(f"QC: corner_transparent={corner_bad}/4, tile_edge_semi={edge_bad}")

# ---- 输出 icns ----
iconset = os.path.join(OUT, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for base, scale in [(16, 2), (16, 1), (32, 2), (32, 1), (128, 2), (128, 1),
                    (256, 2), (256, 1), (512, 2), (512, 1)]:
    s = base * scale
    canvas.resize((s, s), Image.LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"))
icns = os.path.join(OUT, "AppIcon.icns")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)

# 网站 logo / favicon：全出血方形（网站端自行切圆角）
full = diag_grad(1024, (47, 128, 255), (8, 32, 108))
radial_glow(full, (250, 170), 620, (150, 205, 255), 95)
radial_glow(full, (900, 950), 560, (3, 8, 50), 130)
band2 = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
ImageDraw.Draw(band2).polygon([(-120, 640), (540, -160), (880, -160), (-120, 900)],
                              fill=(255, 255, 255, 34))
full.alpha_composite(band2.filter(ImageFilter.GaussianBlur(48)))
full.alpha_composite(txt_layer.resize((1024, 1024), Image.LANCZOS) if False else Image.new("RGBA",(1024,1024),(0,0,0,0)))
# 直接把 tile 内容放大贴到 1024 全出血
full.paste(tile.resize((1024, 1024), Image.LANCZOS), (0, 0))
full.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "logo_512.png"))
full.resize((180, 180), Image.LANCZOS).save(os.path.join(OUT, "logo_180.png"))
full.resize((64, 64), Image.LANCZOS).convert("RGB").save(os.path.join(OUT, "favicon_64.png"))

# 预览
canvas.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "icon_preview.png"))
print("OK:", icns)
