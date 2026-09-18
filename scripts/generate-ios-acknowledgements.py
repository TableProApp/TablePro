#!/usr/bin/env python3
"""Write the iOS app's Acknowledgements.json from the third-party license inventory.

The iOS app does not link Yams, so it reads a JSON projection of licenses.yml: every component
whose platforms include ios, sorted by name, with only the fields its Acknowledgements screen shows.
ThirdPartyLicenseInventoryTests fails when the committed file differs from this output.

Usage:
  scripts/generate-ios-acknowledgements.py
"""

import json
import sys
from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
INVENTORY_PATH = REPOSITORY_ROOT / "TablePro/Resources/ThirdPartyLicenses/licenses.yml"
OUTPUT_PATH = REPOSITORY_ROOT / "TableProMobile/TableProMobile/Acknowledgements/Acknowledgements.json"

PROJECTED_FIELDS = ("id", "name", "version", "spdx", "copyrights", "homepageURL", "textFile")
KNOWN_PLATFORMS = {"macos", "ios"}
DEFAULT_PLATFORMS = ["macos"]
TARGET_PLATFORM = "ios"


def load_inventory(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return yaml.load(handle, Loader=yaml.BaseLoader)


def platforms_of(component: dict) -> list[str]:
    platforms = component.get("platforms", DEFAULT_PLATFORMS)
    unknown = sorted(set(platforms) - KNOWN_PLATFORMS)
    if unknown:
        raise ValueError(f"{component['id']} names unknown platforms: {', '.join(unknown)}")
    return platforms


def project(component: dict) -> dict:
    return {field: component.get(field) for field in PROJECTED_FIELDS}


def sort_key(component: dict) -> tuple[str, str]:
    return (component["name"].lower(), component["id"])


def main() -> int:
    try:
        components = load_inventory(INVENTORY_PATH)
        shipped = [project(c) for c in components if TARGET_PLATFORM in platforms_of(c)]
    except (OSError, yaml.YAMLError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    shipped.sort(key=sort_key)
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(shipped, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {len(shipped)} components to {OUTPUT_PATH.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
