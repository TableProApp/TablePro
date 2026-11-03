#!/usr/bin/env python3
# Writes the MSIX logos in src/TablePro.App/Assets from the app icon, at every scale and target size the
# Windows icon guidance lists. Run it after the icon changes. Needs rsvg-convert (librsvg) and Pillow.

import io
import pathlib
import subprocess

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "linux" / "data" / "icons" / "hicolor" / "scalable" / "apps" / "app.tablepro.TablePro.svg"
ASSETS = ROOT / "windows" / "src" / "TablePro.App" / "Assets"

SCALES = (100, 125, 150, 200, 400)
TARGET_SIZES = (16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256)
# The icon's plate fills its own bounds, so the plated, dark and light variants are one image.
TARGET_FORMS = ("", "_altform-unplated", "_altform-lightunplated")

# Manifest logo, base size, and the share of the asset's height the plate takes.
LOGOS = (
    ("Square44x44Logo", (44, 44), 1.0),
    ("StoreLogo", (50, 50), 1.0),
    ("Square71x71Logo", (71, 71), 0.9067),
    ("Square150x150Logo", (150, 150), 0.9067),
    ("Square310x310Logo", (310, 310), 0.9067),
    ("Wide310x150Logo", (310, 150), 0.7067),
    ("SplashScreen", (620, 300), 0.7067),
)

# The plate spans 8 to 120 of the icon's 128 unit view box.
ICON_VIEW_BOX = 'viewBox="0 0 128 128"'
PLATE_VIEW_BOX = 'viewBox="8 8 112 112"'


def plate(size: int) -> Image.Image:
    svg = SOURCE.read_text(encoding="utf-8")
    if ICON_VIEW_BOX not in svg:
        raise SystemExit(f"{SOURCE} no longer has {ICON_VIEW_BOX}; update where the plate sits")
    svg = svg.replace(ICON_VIEW_BOX, PLATE_VIEW_BOX, 1)
    png = subprocess.run(
        ["rsvg-convert", "--width", str(size), "--height", str(size), "--format", "png"],
        input=svg.encode("utf-8"),
        capture_output=True,
        check=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def compose(width: int, height: int, share: float) -> Image.Image:
    side = round(height * share)
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.alpha_composite(plate(side), ((width - side) // 2, (height - side) // 2))
    return canvas


def save(image: Image.Image, name: str) -> None:
    image.save(ASSETS / name, format="PNG", optimize=True)


def main() -> None:
    for old in ASSETS.glob("*.png"):
        if old.name != "AppIcon.png":
            old.unlink()
    for name, (width, height), share in LOGOS:
        for scale in SCALES:
            save(compose(round(width * scale / 100), round(height * scale / 100), share), f"{name}.scale-{scale}.png")
    for size in TARGET_SIZES:
        image = compose(size, size, 1.0)
        for form in TARGET_FORMS:
            save(image, f"Square44x44Logo.targetsize-{size}{form}.png")


if __name__ == "__main__":
    main()
