#!/usr/bin/env python3
"""
Generate POS launcher icon for Android app
Theme color: #1565C0 (Blue 800 - Material Design)
Creates a professional icon with bold "POS" text
"""

from PIL import Image, ImageDraw, ImageFont
import os

def create_pos_icon(size):
    """Create a POS launcher icon at the given size."""

    # App theme color: Color(0xFF1565C0) = #1565C0
    # Primary blue (dark)
    primary_dark  = (13, 71, 161)    # #0D47A1 - darker shade
    primary       = (21, 101, 192)   # #1565C0 - app primary color
    primary_light = (30, 136, 229)   # #1E88E5 - lighter shade

    white = (255, 255, 255)
    gold  = (255, 214, 0)            # accent gold for contrast

    # ── Background: rounded square with vertical gradient ──────────────────
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))

    # Gradient fill
    gradient = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / (size - 1)
        r = int(primary_dark[0] + (primary_light[0] - primary_dark[0]) * t)
        g = int(primary_dark[1] + (primary_light[1] - primary_dark[1]) * t)
        b = int(primary_dark[2] + (primary_light[2] - primary_dark[2]) * t)
        gd.line([(0, y), (size - 1, y)], fill=(r, g, b, 255))

    # Rounded-corner mask
    radius = int(size * 0.20)
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    gradient.putalpha(mask)
    img = gradient
    draw = ImageDraw.Draw(img)

    # ── Subtle inner glow / highlight at top ───────────────────────────────
    glow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gd2 = ImageDraw.Draw(glow)
    gd2.ellipse(
        [int(size * 0.1), int(-size * 0.3),
         int(size * 0.9), int(size * 0.5)],
        fill=(255, 255, 255, 25)
    )
    img = Image.alpha_composite(img, glow)
    draw = ImageDraw.Draw(img)

    # ── Gold accent stripe at top ──────────────────────────────────────────
    stripe_h = max(4, int(size * 0.07))
    stripe_y = int(size * 0.10)
    pad_x    = int(size * 0.18)
    draw.rounded_rectangle(
        [pad_x, stripe_y, size - pad_x, stripe_y + stripe_h],
        radius=stripe_h // 2,
        fill=gold
    )

    # ── "POS" text — large, bold, centred ─────────────────────────────────
    # Target: text fills ~70% of icon width
    target_w = int(size * 0.70)

    font_paths = [
        '/System/Library/Fonts/Helvetica.ttc',
        '/System/Library/Fonts/Arial Bold.ttf',
        '/System/Library/Fonts/Arial.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    ]

    def load_font(pt):
        for fp in font_paths:
            if os.path.exists(fp):
                try:
                    return ImageFont.truetype(fp, pt)
                except Exception:
                    pass
        return ImageFont.load_default()

    # Binary-search for the right font size
    lo, hi = int(size * 0.20), int(size * 0.75)
    font = load_font(hi)
    for _ in range(20):
        mid = (lo + hi) // 2
        f = load_font(mid)
        bb = draw.textbbox((0, 0), "POS", font=f)
        w = bb[2] - bb[0]
        if w < target_w:
            lo = mid
        else:
            hi = mid
        if hi - lo <= 1:
            break
    font = load_font(lo)

    bb = draw.textbbox((0, 0), "POS", font=font)
    tw = bb[2] - bb[0]
    th = bb[3] - bb[1]

    # Vertical centre: slightly above middle to leave room for tagline
    cx = (size - tw) // 2 - bb[0]
    cy = int(size * 0.30)

    # Drop shadow
    shadow_off = max(2, int(size * 0.012))
    draw.text((cx + shadow_off, cy + shadow_off), "POS",
              font=font, fill=(0, 0, 0, 90))

    # White text
    draw.text((cx, cy), "POS", font=font, fill=white)

    # ── Thin separator line ────────────────────────────────────────────────
    sep_y = cy + th + int(size * 0.04)
    sep_pad = int(size * 0.22)
    draw.line([(sep_pad, sep_y), (size - sep_pad, sep_y)],
              fill=(255, 255, 255, 100), width=max(1, int(size * 0.012)))

    # ── Tagline "RESTO" below separator ───────────────────────────────────
    tag_pt = max(8, int(size * 0.10))
    tag_font = load_font(tag_pt)
    tag_bb = draw.textbbox((0, 0), "RESTO", font=tag_font)
    tag_w = tag_bb[2] - tag_bb[0]
    tag_x = (size - tag_w) // 2 - tag_bb[0]
    tag_y = sep_y + int(size * 0.03)
    draw.text((tag_x, tag_y), "RESTO", font=tag_font,
              fill=(255, 255, 255, 200))

    # ── Bottom gold dot row (decorative keypad hint) ───────────────────────
    dot_r   = max(2, int(size * 0.030))
    dot_gap = int(size * 0.090)
    n_dots  = 4
    total   = n_dots * dot_r * 2 + (n_dots - 1) * (dot_gap - dot_r * 2)
    dx_start = (size - total) // 2
    dot_y   = int(size * 0.82)

    for i in range(n_dots):
        dx = dx_start + i * dot_gap
        color = gold if i % 2 == 0 else (255, 255, 255, 180)
        if isinstance(color, tuple) and len(color) == 3:
            color = color + (220,)
        draw.ellipse([dx, dot_y, dx + dot_r * 2, dot_y + dot_r * 2],
                     fill=color)

    return img


def generate_icons():
    sizes = {
        'mipmap-mdpi':    48,
        'mipmap-hdpi':    72,
        'mipmap-xhdpi':   96,
        'mipmap-xxhdpi':  144,
        'mipmap-xxxhdpi': 192,
    }

    base_path = 'android/app/src/main/res'
    print("Generating POS launcher icons (theme: #1565C0)...")

    for folder, size in sizes.items():
        out_dir = os.path.join(base_path, folder)
        os.makedirs(out_dir, exist_ok=True)
        icon = create_pos_icon(size)
        out_path = os.path.join(out_dir, 'ic_launcher.png')
        icon.save(out_path, 'PNG')
        print(f"  ✓ {folder}/ic_launcher.png ({size}×{size})")

    # High-res preview
    preview = create_pos_icon(1024)
    preview.save('pos_icon_preview.png', 'PNG')
    print("  ✓ pos_icon_preview.png (1024×1024) — preview")
    print("\nDone!")


if __name__ == '__main__':
    generate_icons()
