#!/usr/bin/env python3
# Gathers the files a Linux release or beta publishes from the release
# workflow's artifacts into one directory and writes SHA256SUMS. GitHub turns
# the '~' of a package version into '.' in an asset's name, so each package
# is renamed after the tag's version, the system it was built for and its
# architecture. Every package must be there for amd64 and arm64.
# Usage: release_assets.py --version X.Y.Z[-beta.N] <artifacts dir> <output dir>

import argparse
import hashlib
import re
import shutil
import sys
from pathlib import Path

from check_packaging import RELEASE_VERSION, package_version

DEB = re.compile(r"^tablepro_(?P<version>[^_]+)-0ppa\d+~(?P<series>\d+\.\d+)_(?P<arch>[a-z0-9]+)\.deb$")
RPM = re.compile(r"^tablepro-(?P<version>[0-9][^-]*)-\d+\.fc(?P<fedora>\d+)\.(?P<arch>[a-z0-9_]+)\.rpm$")
FLATPAK = re.compile(r"^tablepro-(?P<arch>[a-z0-9_]+)\.flatpak$")
DEB_ARCHES = ("amd64", "arm64")
RPM_ARCHES = ("x86_64", "aarch64")


class AssetError(Exception):
    pass


def asset_name(file, version):
    """The release asset name of a built file, or None for a file the release does not carry."""
    name = file.name
    if name in (f"tablepro-{version}.tar.xz", f"tablepro-{version}-vendor.tar.xz", "tablepro.pot"):
        return name
    packaged = package_version(version)
    for pattern, kind in ((DEB, "deb"), (RPM, "rpm")):
        match = pattern.match(name)
        if match is None:
            continue
        if match["version"] != packaged:
            raise AssetError(f"{name} packages {match['version']}, not {packaged}")
        arch = match["arch"]
        if kind == "deb" and arch in DEB_ARCHES:
            return f"tablepro-{version}-ubuntu-{match['series']}-{arch}.deb"
        if kind == "rpm" and arch in RPM_ARCHES:
            return f"tablepro-{version}-fedora-{match['fedora']}-{arch}.rpm"
        return None
    match = FLATPAK.match(name)
    if match and match["arch"] in RPM_ARCHES:
        return f"tablepro-{version}-{match['arch']}.flatpak"
    return None


def collect(artifacts, version):
    """Maps each asset name to the built file it comes from."""
    assets = {}
    for file in sorted(path for path in artifacts.rglob("*") if path.is_file()):
        name = asset_name(file, version)
        if name is None:
            continue
        if name in assets:
            raise AssetError(f"{file} and {assets[name]} would both publish as {name}")
        assets[name] = file
    return assets


def missing(assets, version):
    prefix = f"tablepro-{version}-"
    systems = {name.removeprefix(prefix).rsplit("-", 1)[0] for name in assets if name.endswith((".deb", ".rpm"))}
    expected = {f"tablepro-{version}.tar.xz", f"tablepro-{version}-vendor.tar.xz", "tablepro.pot"}
    expected |= {f"{prefix}{arch}.flatpak" for arch in RPM_ARCHES}
    for distribution, arches, suffix in (("ubuntu", DEB_ARCHES, "deb"), ("fedora", RPM_ARCHES, "rpm")):
        built = {system for system in systems if system.startswith(f"{distribution}-")}
        if not built:
            expected.add(f"{prefix}{distribution}-*.{suffix}")
        expected |= {f"{prefix}{system}-{arch}.{suffix}" for system in built for arch in arches}
    return sorted(expected - set(assets))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def gather(artifacts, out, version):
    if not RELEASE_VERSION.match(version):
        raise AssetError(f"version {version} is neither X.Y.Z nor a beta such as X.Y.Z-beta.1")
    assets = collect(artifacts, version)
    absent = missing(assets, version)
    if absent:
        raise AssetError(f"the artifacts have no {', '.join(absent)}")
    out.mkdir(parents=True, exist_ok=True)
    sums = []
    for name, file in sorted(assets.items()):
        shutil.copyfile(file, out / name)
        sums.append(f"{sha256(out / name)}  {name}\n")
    (out / "SHA256SUMS").write_text("".join(sums), encoding="utf-8")
    return sorted(assets)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Gather a Linux release's files and write SHA256SUMS.")
    parser.add_argument("--version", required=True)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args(argv)
    try:
        names = gather(args.artifacts, args.out, args.version)
    except (AssetError, OSError) as error:
        print(f"release_assets.py: {error}", file=sys.stderr)
        return 1
    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
