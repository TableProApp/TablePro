#!/usr/bin/env python3
# Gathers the files a Linux release or beta publishes from the release
# workflow's artifacts into one directory and writes SHA256SUMS, then checks
# a directory of them. GitHub turns the '~' of a package version into '.' in
# an asset's name, so each package is renamed after the tag's version, the
# system it was built for and its architecture. release-matrix.json declares
# every Ubuntu series, Fedora release and architecture a release carries, and
# linux-packages.yml builds from the same file; the assets must be exactly
# those.
#
# Usage:
#   release_assets.py gather --version X.Y.Z[-beta.N] <artifacts dir> <output dir>
#   release_assets.py verify --version X.Y.Z[-beta.N] <assets dir>
#       Checks the names against the matrix, each file against SHA256SUMS, and
#       each package's name, version and architecture against its file name.

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from check_packaging import RELEASE_VERSION, package_version

MATRIX = Path(__file__).resolve().parent / "release-matrix.json"
DEB = re.compile(r"^tablepro_(?P<version>[^_]+)-0ppa\d+~(?P<series>\d+\.\d+)_(?P<arch>[a-z0-9]+)\.deb$")
RPM = re.compile(r"^tablepro-(?P<version>[0-9][^-]*)-\d+\.fc(?P<fedora>\d+)\.(?P<arch>[a-z0-9_]+)\.rpm$")
FLATPAK = re.compile(r"^tablepro-(?P<arch>[a-z0-9_]+)\.flatpak$")


class AssetError(Exception):
    pass


def load_matrix(path=MATRIX):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def expected_assets(version, matrix):
    """Every asset name a release of this version carries, mapped to what its package must declare."""
    expected = {
        f"tablepro-{version}.tar.xz": None,
        f"tablepro-{version}-vendor.tar.xz": None,
        "tablepro.pot": None,
    }
    for arch in matrix["architectures"]:
        for ubuntu in matrix["ubuntu"]:
            expected[f"tablepro-{version}-ubuntu-{ubuntu['version']}-{arch['deb']}.deb"] = ("deb", arch["deb"])
        for fedora in matrix["fedora"]:
            expected[f"tablepro-{version}-fedora-{fedora}-{arch['rpm']}.rpm"] = ("rpm", arch["rpm"])
        expected[f"tablepro-{version}-{arch['flatpak']}.flatpak"] = None
    return expected


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
        if match["arch"] == "src":
            return None
        if match["version"] != packaged:
            raise AssetError(f"{name} packages {match['version']}, not {packaged}")
        if kind == "deb":
            return f"tablepro-{version}-ubuntu-{match['series']}-{match['arch']}.deb"
        return f"tablepro-{version}-fedora-{match['fedora']}-{match['arch']}.rpm"
    match = FLATPAK.match(name)
    if match:
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


def compare(names, expected):
    missing = sorted(set(expected) - set(names))
    if missing:
        raise AssetError(f"the release has no {', '.join(missing)}")
    extra = sorted(set(names) - set(expected))
    if extra:
        raise AssetError(f"release-matrix.json declares no {', '.join(extra)}")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def check_version(version):
    if not RELEASE_VERSION.match(version):
        raise AssetError(f"version {version} is neither X.Y.Z nor a beta such as X.Y.Z-beta.1")


def gather(artifacts, out, version, matrix):
    check_version(version)
    assets = collect(artifacts, version)
    compare(assets, expected_assets(version, matrix))
    out.mkdir(parents=True, exist_ok=True)
    sums = []
    for name, file in sorted(assets.items()):
        shutil.copyfile(file, out / name)
        sums.append(f"{sha256(out / name)}  {name}\n")
    (out / "SHA256SUMS").write_text("".join(sums), encoding="utf-8")
    return sorted(assets)


def deb_fields(path):
    output = subprocess.run(
        ["dpkg-deb", "--show", "--showformat=${Package} ${Version} ${Architecture}", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return tuple(output.split())


def rpm_fields(path):
    output = subprocess.run(
        ["rpm", "--query", "--package", "--nosignature", "--queryformat", "%{NAME} %{VERSION} %{ARCH}", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return tuple(output.split())


def verify(directory, version, matrix, read_deb=deb_fields, read_rpm=rpm_fields):
    check_version(version)
    expected = expected_assets(version, matrix)
    sums_file = directory / "SHA256SUMS"
    if not sums_file.is_file():
        raise AssetError(f"{directory} has no SHA256SUMS")
    listed = {}
    for line in sums_file.read_text(encoding="utf-8").splitlines():
        digest, _, name = line.partition("  ")
        listed[name] = digest
    compare(listed, expected)
    present = sorted(path.name for path in directory.iterdir() if path.is_file() and path.name != "SHA256SUMS")
    compare(present, expected)
    packaged = package_version(version)
    for name, digest in sorted(listed.items()):
        if sha256(directory / name) != digest:
            raise AssetError(f"{name} does not match its SHA256SUMS line")
        kind = expected[name]
        if kind is None:
            continue
        package, declared, arch = (read_deb if kind[0] == "deb" else read_rpm)(directory / name)
        if package != "tablepro" or arch != kind[1]:
            raise AssetError(f"{name} holds {package} for {arch}")
        if kind[0] == "deb" and not declared.startswith(f"{packaged}-0ppa"):
            raise AssetError(f"{name} holds version {declared}, not {packaged}-0ppaN")
        if kind[0] == "rpm" and declared != packaged:
            raise AssetError(f"{name} holds version {declared}, not {packaged}")
    return sorted(listed)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Gather or check a Linux release's files.")
    commands = parser.add_subparsers(dest="command", required=True)
    gather_command = commands.add_parser("gather")
    gather_command.add_argument("--version", required=True)
    gather_command.add_argument("artifacts", type=Path)
    gather_command.add_argument("out", type=Path)
    verify_command = commands.add_parser("verify")
    verify_command.add_argument("--version", required=True)
    verify_command.add_argument("directory", type=Path)
    args = parser.parse_args(argv)
    try:
        matrix = load_matrix()
        if args.command == "gather":
            names = gather(args.artifacts, args.out, args.version, matrix)
        else:
            names = verify(args.directory, args.version, matrix)
    except (AssetError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release_assets.py: {error}", file=sys.stderr)
        return 1
    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
