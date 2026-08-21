#!/usr/bin/env python3
"""Draw the grey "Screenshot coming soon" card that stands in for a shot not taken yet.

The card is a marker, not a defect. It reserves the filename the page already references, so
replacing it is dropping a PNG in with the same name and nothing else. Colours, size and layout
match the cards already in docs/images so a page never shows two different placeholder designs.

    python3 docs/scripts/make-placeholder.py "Data grid" data-grid

writes docs/images/data-grid.png and docs/images/data-grid-dark.png.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZE = (1560, 960)
INSET = 24
RADIUS = 16
DASH, GAP = 12, 10

THEMES = {
    "": {"bg": "#F5F5F5", "line": "#D1D1D1", "title": "#595959", "sub": "#8C8C8C"},
    "-dark": {"bg": "#1C1C1C", "line": "#2E2E2E", "title": "#BFBFBF", "sub": "#808080"},
}

FONTS = ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc")


def font(size: int, weight: float):
    for path in FONTS:
        if Path(path).exists():
            try:
                f = ImageFont.truetype(path, size)
                try:
                    f.set_variation_by_axes([weight])
                except Exception:
                    pass
                return f
            except OSError:
                continue
    return ImageFont.load_default()


def dashed_rect(draw: ImageDraw.ImageDraw, box, colour: str, width: int = 3) -> None:
    left, top, right, bottom = box
    for x in range(left + RADIUS, right - RADIUS, DASH + GAP):
        end = min(x + DASH, right - RADIUS)
        draw.line([(x, top), (end, top)], fill=colour, width=width)
        draw.line([(x, bottom), (end, bottom)], fill=colour, width=width)
    for y in range(top + RADIUS, bottom - RADIUS, DASH + GAP):
        end = min(y + DASH, bottom - RADIUS)
        draw.line([(left, y), (left, end)], fill=colour, width=width)
        draw.line([(right, y), (right, end)], fill=colour, width=width)
    for xy, start in (
        ((left, top, left + RADIUS * 2, top + RADIUS * 2), 180),
        ((right - RADIUS * 2, top, right, top + RADIUS * 2), 270),
        ((right - RADIUS * 2, bottom - RADIUS * 2, right, bottom), 0),
        ((left, bottom - RADIUS * 2, left + RADIUS * 2, bottom), 90),
    ):
        draw.arc(xy, start, start + 90, fill=colour, width=width)


def centred(draw: ImageDraw.ImageDraw, text: str, y: int, f, colour: str) -> None:
    left, top, right, bottom = draw.textbbox((0, 0), text, font=f)
    draw.text(((SIZE[0] - (right - left)) / 2 - left, y - (bottom - top) / 2 - top),
              text, font=f, fill=colour)


def build(title: str, slug: str, out_dir: Path) -> list[Path]:
    written = []
    for suffix, theme in THEMES.items():
        image = Image.new("RGB", SIZE, theme["bg"])
        draw = ImageDraw.Draw(image)
        dashed_rect(draw, (INSET, INSET, SIZE[0] - INSET, SIZE[1] - INSET), theme["line"])
        centred(draw, title, 440, font(64, 700), theme["title"])
        centred(draw, "Screenshot coming soon", 525, font(38, 400), theme["sub"])
        path = out_dir / f"{slug}{suffix}.png"
        image.save(path, optimize=True)
        written.append(path)
    return written


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    out = Path(__file__).resolve().parent.parent / "images"
    for path in build(sys.argv[1], sys.argv[2], out):
        print(f"{path.relative_to(path.parent.parent)}  {path.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
