# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==11.3.0"]
# ///
"""Regenerates the two synthetic text fixtures used by the Live Text debug runs:

    Tests/Fixtures/text-select-row-skipped.png   2000 x 288, a numbered list with sub-bullets and one wrapped row
    Tests/Fixtures/terminal-list-blurred.png     2560 x 1600, a "- " list in a monospaced panel over a blurred blob wallpaper

Run from the repository root: uv run Tests/Fixtures/tools/make_text_fixtures.py
Everything drawn is invented text and generated shapes; no screen capture is involved.
"""
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent.parent
MONO = "/System/Library/Fonts/Menlo.ttc"
SANS = "/System/Library/Fonts/Helvetica.ttc"


def rows_fixture() -> Image.Image:
    w, h = 2000, 288
    img = Image.new("RGB", (w, h), (52, 56, 72))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=(int(60 - 20 * t), int(64 - 22 * t), int(86 - 26 * t)))
    d.rectangle([228, 55, 1767, h], fill=(27, 29, 43))
    # Title bar with a close button, title and toolbar glyphs; the glyphs sit inside x 1700-1890, y 0-34.
    d.ellipse([12, 8, 34, 30], fill=(120, 122, 132))
    d.text((50, 19), "Window", font=ImageFont.truetype(SANS, 22, index=1), fill=(235, 235, 240), anchor="lm")
    for cx in (1722, 1793, 1863):
        d.ellipse([cx - 11, 7, cx + 11, 29], outline=(190, 192, 200), width=2)
    d.rounded_rectangle([1907, 4, 1983, 32], 8, fill=(80, 82, 94))
    d.text((1945, 19), "Done", font=ImageFont.truetype(SANS, 22), fill=(170, 172, 180), anchor="mm")
    font = ImageFont.truetype(MONO, 17)
    lines = [
        "Decisions for you",
        "1. Theme setting: defaults write com.example.demo Theme d, or a, switches it live.",
        "   - A is the cleaner version. The old one also had a bug that left one of its five dots undrawn.",
        "   - D at 1x reads as loose dots. Its arch can come down 1 pt to match the reference.",
        "2. Hint label: remove it. On the 16 sample cases it never reached a second hint, so it now shows only when there's a real alternative,",
        "   which is almost never.",
        "3. An intro animation: none exists today. Do you want a quick fade, or the panel growing into place?",
        "4. Cleanup: should I remove the 30+ old sample files and archives, and clear the old cache (3.3 MB) in /tmp/demo-cache?",
        "",
        "Details and caveats are in docs/notes.md.",
    ]
    ys = [80, 101, 122, 143, 163, 183, 204, 224, 245, 265]
    for text, y in zip(lines, ys):
        d.text((246, y), text, font=font, fill=(236, 236, 242), anchor="lm")
    return img


def terminal_fixture() -> Image.Image:
    w, h = 2560, 1600
    rng = random.Random(7)
    bg = Image.new("RGB", (w, h), (46, 50, 82))
    d = ImageDraw.Draw(bg)
    for _ in range(70):
        r = rng.randint(60, 260)
        x, y = rng.randint(-r, w), rng.randint(-r, h)
        d.ellipse([x, y, x + 2 * r, y + 2 * r], fill=tuple(rng.randint(40, 230) for _ in range(3)))
    bg = bg.filter(ImageFilter.GaussianBlur(22))
    panel = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(panel).rounded_rectangle([120, 90, 2440, 1511], 22, fill=(28, 30, 44, 235))
    img = Image.alpha_composite(bg.convert("RGBA"), panel).convert("RGB")
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(MONO, 27)
    lines = [
        "Plan for the garden planner screen", "",
        "The card around a plant has four parts the user can change:",
        "- watering interval;", "- sun exposure (hours);", "- pot size of the plant;", "- soil mix for the pot.", "",
        "Defaults stay what they are now:",
        "- Default: medium pot, partial sun, the same as today.",
        "  - Small keeps the plant tight to a windowsill.",
        "  - Large leaves room for a deep root.",
        "- Custom: the four values above, each with its own slider.", "",
        "It would sit next to Plant list in Settings, under Appearance,",
        "with a preview that redraws as the sliders move.", "",
        "Open questions:",
        "- does the soil mix follow the pot's own size;",
        "- should the pot scale with the plant's height;",
        "- is a moisture sensor for the card worth it.", "",
        "Next steps: build the screen, wire the preview, then run the layout",
        "checks and render the states in light and dark.",
    ]
    for i, text in enumerate(lines):
        if text:
            d.text((170, 155 + 46.08 * i), text, font=font, fill=(238, 238, 244), anchor="lm")
    return img


if __name__ == "__main__":
    rows_fixture().save(OUT / "text-select-row-skipped.png", optimize=True)
    terminal_fixture().save(OUT / "terminal-list-blurred.png", optimize=True)
