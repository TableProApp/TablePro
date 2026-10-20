import argparse
from pathlib import Path
import re
import sys
import tomllib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def release_version(root):
    return tomllib.loads((root / "Cargo.toml").read_text())["workspace"]["package"]["version"]


def problems(root):
    manifest = tomllib.loads((root / "Cargo.toml").read_text())
    version = release_version(root)
    errors = []
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        errors.append("workspace version must be a release version such as 0.2.0")
    for member in manifest["workspace"]["members"]:
        for directory in sorted(root.glob(member)):
            package = tomllib.loads((directory / "Cargo.toml").read_text())["package"]
            if package.get("version") != {"workspace": True}:
                errors.append(f"{directory.relative_to(root)}/Cargo.toml must inherit the workspace version")
    meson = (root / "meson.build").read_text()
    match = re.search(r"project\([^,]+,\s*version:\s*['\"]([^'\"]+)['\"]", meson)
    if not match or match.group(1) != version:
        errors.append("Meson version differs from the workspace version")
    metadata = ET.parse(root / "apps/linux/flatpak/com.tablepro.linux.metainfo.xml")
    newest = metadata.find("releases/release")
    if newest is None or newest.get("version") != version:
        errors.append("newest AppStream entry differs from the workspace version")
    return errors


def main():
    parser = argparse.ArgumentParser(description="Check BookiE release version consistency.")
    parser.add_argument("--print", action="store_true", dest="print_version")
    args = parser.parse_args()
    try:
        if args.print_version:
            print(release_version(ROOT))
            return 0
        errors = problems(ROOT)
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f"release version check failed: {error}", file=sys.stderr)
        return 1
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"release versions: {release_version(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
