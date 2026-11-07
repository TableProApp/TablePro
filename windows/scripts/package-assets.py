#!/usr/bin/env python3
# Writes the MSIX logos and the window icon in src/TablePro.App/Assets from the app icon, at every scale and
# target size the Windows icon guidance lists. Run it after the icon changes. Needs rsvg-convert (librsvg) and Pillow.

import io
import pathlib
import subprocess

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "linux" / "data" / "icons" / "hicolor" / "scalable" / "apps" / "app.tablepro.TablePro.svg"
ASSETS = ROOT / "windows" / "src" / "TablePro.App" / "Assets"

# The Linux icon holds the brand art in the square shape guide of GNOME's app icon template, 12 to 116 of 128.
ICON_VIEW_BOX = 'viewBox="0 0 128 128"'
BRAND_VIEW_BOX = 'viewBox="12 12 104 104"'

# App icon design, The grid and rounded corners: a square shape sits on the keyline 3 px inside the 48 px grid.
KEYLINE_INSET = 3 / 48

# App icon construction, How icon sizes relate to the MSIX manifest.
SCALES = (100, 125, 150, 200, 400)
# App icon construction, App icon: App List Target Size.
TARGET_SIZES = (16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256)
# App icon construction, App icon: the light and dark theme files are required, or Windows plates the icon.
TARGET_FORMS = ("", "_altform-unplated", "_altform-lightunplated")
# App icon construction, Icon scaling: the title bar sizes, and 256 so Windows only scales down.
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 256)

LOGOS = (
    ("Square44x44Logo", (44, 44)),
    ("StoreLogo", (50, 50)),
    ("Square71x71Logo", (71, 71)),
    ("Square150x150Logo", (150, 150)),
    ("Square310x310Logo", (310, 310)),
    ("Wide310x150Logo", (310, 150)),
    ("SplashScreen", (620, 300)),
)


def brand(size: int) -> Image.Image:
    svg = SOURCE.read_text(encoding="utf-8")
    if ICON_VIEW_BOX not in svg:
        raise SystemExit(f"{SOURCE} no longer has {ICON_VIEW_BOX}; update where the brand art sits")
    svg = svg.replace(ICON_VIEW_BOX, BRAND_VIEW_BOX, 1)
    png = subprocess.run(
        ["rsvg-convert", "--width", str(size), "--height", str(size), "--format", "png"],
        input=svg.encode("utf-8"),
        capture_output=True,
        check=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def compose(width: int, height: int) -> Image.Image:
    side = height - 2 * round(height * KEYLINE_INSET)
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.alpha_composite(brand(side), ((width - side) // 2, (height - side) // 2))
    return canvas


def save(image: Image.Image, name: str) -> None:
    image.save(ASSETS / name, format="PNG", optimize=True)


def main() -> None:
    for old in ASSETS.glob("*.png"):
        old.unlink()
    for name, (width, height) in LOGOS:
        for scale in SCALES:
            save(compose(round(width * scale / 100), round(height * scale / 100)), f"{name}.scale-{scale}.png")
    for size in TARGET_SIZES:
        image = compose(size, size)
        for form in TARGET_FORMS:
            save(image, f"Square44x44Logo.targetsize-{size}{form}.png")
    save(compose(64, 64), "AppIcon.png")
    icons = [compose(size, size) for size in ICO_SIZES]
    icons[-1].save(ASSETS / "AppIcon.ico", format="ICO", sizes=[(s, s) for s in ICO_SIZES], append_images=icons[:-1])


if __name__ == "__main__":
    main()
