#!/usr/bin/env python3
"""Build the Chrome Web Store listing graphics for Custode Browser Autofill.

Usage: python3 tool/build_chrome_web_store_assets.py

Writes docs/store_assets/chrome_web_store/. Pillow only. The mark is drawn by
the icon-family generator's own component painter, so the geometry cannot drift
from the app icon. Text uses the fonts the app bundles (assets/fonts/).
"""

from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import build_app_icon_family as icons

REPO = icons.REPO
OUT = REPO / "docs/store_assets/chrome_web_store"
EXT = REPO / "assets/logo/app_icon_family"
FONTS = REPO / "assets/fonts"
SS = icons.SS

PEACH, ORANGE, DARK = icons.PEACH[:3], icons.ORANGE[:3], icons.DARK[:3]
ACCENT_300 = (255, 198, 165)
ACCENT_500 = (214, 127, 72)
ACCENT_800 = (100, 51, 18)
SHEET_BG = (241, 243, 244)
SHEET_INK = (32, 30, 29)
SWATCHES = (("white", (255, 255, 255)), ("light gray", SHEET_BG), ("dark", (32, 33, 36)))

# The mark's ink spans 23..77 of the generator's 100-unit canvas.
INK_MIN, INK_SPAN = 23, 54


def font(name: str, size: float) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), round(size))


def mark(diameter: int, *, backed: bool = False) -> Image.Image:
    """The mark alone on alpha, ring outer edge = diameter px.

    backed=True fills the dial face with peach so the dark hub and hand stay
    visible on a dark background.
    """
    high = round(diameter * SS * 100 / INK_SPAN)
    canvas = Image.new("RGBA", (high, high), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    if backed:
        draw.ellipse(icons._scaled_box((27, 27, 73, 73), high), fill=icons.PEACH)
    colours = {"ring": icons.ORANGE, "hand": icons.DARK, "hub": icons.DARK}
    for component in icons.COMPONENTS:
        icons._draw_component(draw, component, high, colours.get(component, icons.SAGE))
    low, side = round(high * INK_MIN / 100), diameter * SS
    # Premultiplied resize: no dark fringe from the transparent pixels.
    ink = canvas.crop((low, low, low + side, low + side)).convert("RGBa")
    return ink.resize((diameter, diameter), Image.Resampling.LANCZOS).convert("RGBA")


def icon_alt(size: int) -> Image.Image:
    """Candidate A: the backed round mark on a transparent canvas."""
    diameter = 112 if size == 128 else size
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    image.alpha_composite(mark(diameter, backed=True), ((size - diameter) // 2,) * 2)
    return image


def gradient(size: tuple[int, int], start: tuple, end: tuple, *, radial: bool = False) -> Image.Image:
    ramp = Image.radial_gradient("L") if radial else Image.linear_gradient("L").rotate(-45)
    if not radial:
        ramp = ramp.crop((48, 48, 208, 208))  # drop the corners the rotation left empty
    mask = ramp.resize(size, Image.Resampling.BICUBIC)
    return Image.composite(Image.new("RGB", size, end), Image.new("RGB", size, start), mask)


def ring(canvas: Image.Image, centre: tuple[float, float], radius: float, width: float, colour: tuple) -> None:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    cx, cy = centre
    ImageDraw.Draw(layer).ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=colour, width=round(width))
    canvas.alpha_composite(layer)


def tile(side: int) -> Image.Image:
    """The app icon: peach rounded tile with the mark, as an RGBA sprite."""
    high = side * SS
    art = Image.new("RGBA", (high, high), (0, 0, 0, 0))
    ImageDraw.Draw(art).rounded_rectangle((0, 0, high - 1, high - 1), radius=round(high * icons.EXT_RADIUS), fill=icons.PEACH)
    art = art.convert("RGBa").resize((side, side), Image.Resampling.LANCZOS).convert("RGBA")
    ink = round(side * 0.62)
    art.alpha_composite(mark(ink), ((side - ink) // 2,) * 2)
    return art


def lockup(canvas: Image.Image, badge, colour: tuple, sub_colour: tuple | None, u: float) -> None:
    """Badge at left, "Custode" wordmark (and optional sub-line) at right, centred as a group.

    badge is a sprite factory taking a pixel size. The group is scaled to leave
    a 36 u side margin on the small tile and capped at 1.25x on the marquee.
    """
    draw = ImageDraw.Draw(canvas)
    width, height = canvas.size
    natural = 124 + 22 + draw.textlength("Custode", font=font("Caprasimo-Regular.ttf", 64 * u)) / u
    u *= min((width / u - 72) / natural, 1.25)
    badge = badge(round(124 * u))
    word_font = font("Caprasimo-Regular.ttf", 64 * u)
    sub_font = font("Figtree-SemiBold.ttf", 24 * u)
    gap = round(22 * u)
    left, top, right, bottom = draw.textbbox((0, 0), "Custode", font=word_font)
    word_w, word_h = right - left, bottom - top
    sub_h = round(34 * u) if sub_colour else 0
    x = (width - (badge.width + gap + word_w)) // 2
    canvas.alpha_composite(badge, (x, (height - badge.height) // 2))
    text_x = x + badge.width + gap
    text_y = (height - (word_h + sub_h)) // 2
    draw.text((text_x - left, text_y - top), "Custode", font=word_font, fill=colour)
    if sub_colour:
        draw.text((text_x + round(2 * u), text_y + word_h + round(10 * u)), "Browser Autofill", font=sub_font, fill=sub_colour)


def promo(variant: str, size: tuple[int, int]) -> Image.Image:
    width, height = size
    u = height / 280  # 1 on the small tile, 2 on the marquee
    if variant == "a-orange":
        canvas = gradient(size, ORANGE, ACCENT_500, radial=True).convert("RGBA")
        centre = (width / 2, height / 2)
        ring(canvas, centre, 196 * u, 26 * u, (*ACCENT_500, 110))
        sprite = tile(round(176 * u))
        canvas.alpha_composite(sprite, ((width - sprite.width) // 2, (height - sprite.height) // 2))
    elif variant == "b-dark":
        canvas = gradient(size, ACCENT_800, DARK, radial=True).convert("RGBA")
        canvas = Image.blend(Image.new("RGBA", size, (*DARK, 255)), canvas, 0.45)
        lockup(canvas, lambda side: mark(side, backed=True), PEACH, ACCENT_300, u)
    elif variant == "c-peach":
        canvas = gradient(size, ACCENT_300, ORANGE).convert("RGBA")
        ring(canvas, (width - 40 * u, height + 30 * u), 230 * u, 70 * u, (*PEACH, 120))
        lockup(canvas, tile, DARK, None, u)
    else:
        raise ValueError(variant)
    return canvas.convert("RGB")


def review_sheet(promos: dict[str, Image.Image], candidates: dict[str, dict[int, Image.Image]]) -> Image.Image:
    sheet = Image.new("RGB", (1500, 1680), SHEET_BG)
    draw = ImageDraw.Draw(sheet)
    label_font = font("Figtree-Regular.ttf", 14)
    head_font = font("Figtree-Bold.ttf", 16)

    def label(x: int, y: int, text: str, bold: bool = False) -> None:
        draw.text((x, y), text, fill=SHEET_INK, font=head_font if bold else label_font)

    small = [name for name in promos if "small" in name]
    marquee = [name for name in promos if "marquee" in name]
    label(40, 24, "Small promo tile 440x280, 100%", bold=True)
    for index, name in enumerate(small):
        sheet.paste(promos[name], (40 + index * 480, 54))
        label(40 + index * 480, 340, name)
    label(40, 384, "Small promo tile at 50% (220x140)", bold=True)
    for index, name in enumerate(small):
        sheet.paste(promos[name].resize((220, 140), Image.Resampling.LANCZOS), (40 + index * 480, 414))
        label(40 + index * 480, 560, f"{name} @50%")
    label(40, 604, "Marquee 1400x560, scaled to 440x176", bold=True)
    for index, name in enumerate(marquee):
        sheet.paste(promos[name].resize((440, 176), Image.Resampling.LANCZOS), (40 + index * 480, 634))
        label(40 + index * 480, 816, name)

    y = 860
    for title, images in candidates.items():
        label(40, y, title, bold=True)
        for index, (swatch_name, swatch) in enumerate(SWATCHES):
            x = 40 + index * 480
            draw.rectangle((x, y + 30, x + 439, y + 229), fill=swatch, outline=(218, 220, 224))
            cursor = x + 40
            for size in (128, 48, 32, 16):
                image = images[size]
                sheet.paste(image, (cursor, y + 130 - size // 2), mask=image.getchannel("A"))
                cursor += size + 40
            label(x, y + 236, f"{swatch_name}: 128 / 48 / 32 / 16")
        y += 290
    label(40, y, "16 px toolbar icons at 8x nearest-neighbour (left: wired tile, right: alt round mark)", bold=True)
    for index, (swatch_name, swatch) in enumerate(SWATCHES):
        x = 40 + index * 480
        draw.rectangle((x, y + 30, x + 439, y + 189), fill=swatch, outline=(218, 220, 224))
        for column, images in enumerate(candidates.values()):
            zoom = images[16].resize((128, 128), Image.Resampling.NEAREST)
            sheet.paste(zoom, (x + 60 + column * 190, y + 46), mask=zoom.getchannel("A"))
    return sheet


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    promos: dict[str, Image.Image] = {}
    for variant in ("a-orange", "b-dark", "c-peach"):
        for kind, size in (("small", (440, 280)), ("marquee", (1400, 560))):
            name = f"promo-{kind}-{variant}.png"
            # Draw at SS x and downscale, like the icon family.
            big = promo(variant, (size[0] * SS, size[1] * SS))
            promos[name] = big.resize(size, Image.Resampling.LANCZOS)
            promos[name].save(OUT / name)
            assert promos[name].size == size and promos[name].mode == "RGB", name

    # Wired icon: the generator's own output, copied verbatim. Alt: candidate A.
    shutil.copyfile(EXT / "ext-128.png", OUT / "store-icon-128.png")
    wired = {size: Image.open(EXT / f"ext-{size}.png").convert("RGBA") for size in (128, 48, 32, 16)}
    alt = {size: icon_alt(size) for size in (128, 48, 32, 16)}
    alt[128].save(OUT / "icon-128-alt.png")
    for name in ("store-icon-128.png", "icon-128-alt.png"):
        with Image.open(OUT / name) as icon:
            assert icon.size == (128, 128) and icon.mode == "RGBA", name
            assert all(icon.getpixel(corner)[3] == 0 for corner in ((0, 0), (127, 0), (0, 127), (127, 127))), name

    sheet = review_sheet(
        promos,
        {
            "store-icon-128.png (wired, B): 96 px peach rounded tile, 16 px transparent padding": wired,
            "icon-128-alt.png (A): round mark alone, 112 px, peach dial face": alt,
        },
    )
    sheet.save(OUT / "review-sheet.png")
    for path in sorted(OUT.glob("*.png")):
        with Image.open(path) as image:
            print(f"{path.relative_to(REPO)}  {image.width}x{image.height}  {image.mode}")


if __name__ == "__main__":
    main()
