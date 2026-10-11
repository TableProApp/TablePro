#!/usr/bin/env python3
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
PATCHES = VENDOR / "patches"
TRIMMED = {"redis": {"benches", "examples", "tests", "release.toml", "CHANGELOG.md"}}


def crate_version(vendored):
    for line in (vendored / "Cargo.toml").read_text().splitlines():
        if line.startswith("version"):
            return line.split('"')[1]
    raise SystemExit(f"no version in {vendored}/Cargo.toml")


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "bookie-vendor-check"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def pristine(name, version, destination):
    expected = fetch_json(f"https://crates.io/api/v1/crates/{name}/{version}")["version"]["checksum"]
    url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit(f"{name} {version}: downloaded archive does not match the registry checksum")
    archive = destination / "crate.tar.gz"
    archive.write_bytes(data)
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter="data")
    return destination / f"{name}-{version}"


def prune(root, names):
    for name in names:
        target = root / name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()


def files(root):
    return sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())


def differences(expected, actual):
    wanted, found = set(files(expected)), set(files(actual))
    problems = [f"{name}: missing" for name in sorted(wanted - found)]
    problems += [f"{name}: not in upstream plus patch" for name in sorted(found - wanted)]
    for name in sorted(wanted & found):
        if (expected / name).read_bytes() != (actual / name).read_bytes():
            problems.append(f"{name}: differs")
    return problems


def make_patch(base, vendored, work):
    left, right = work / "a", work / "b"
    shutil.copytree(base, left)
    shutil.copytree(vendored, right)
    result = subprocess.run(
        ["git", "diff", "--no-index", "--no-color", "--no-prefix", "a", "b"], cwd=work, capture_output=True, text=True
    )
    return result.stdout


def apply_patch(patch_file, target):
    if patch_file.stat().st_size == 0:
        return
    subprocess.run(["patch", "-p1", "--no-backup-if-mismatch", "-s", "-d", str(target), "-i", str(patch_file)], check=True)


def prepared(name, version, work):
    base = pristine(name, version, work)
    prune(base, TRIMMED.get(name, ()))
    return base


def crates():
    return sorted(path.name for path in VENDOR.iterdir() if (path / "Cargo.toml").is_file())


def check(argv):
    failed = []
    for name in crates():
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            base = prepared(name, crate_version(VENDOR / name), work)
            apply_patch(PATCHES / f"{name}.patch", base)
            problems = differences(base, VENDOR / name)
        for problem in problems:
            failed.append(f"vendor/{name}/{problem}")
    for line in failed:
        print(f"error: {line}", file=sys.stderr)
    print(f"vendor-patches: {'ok' if not failed else f'{len(failed)} error(s)'} ({len(crates())} crates)")
    return 1 if failed else 0


def generate(argv):
    for name in argv or crates():
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            base = prepared(name, crate_version(VENDOR / name), work)
            PATCHES.mkdir(exist_ok=True)
            (PATCHES / f"{name}.patch").write_text(make_patch(base, VENDOR / name, work))
    return 0


def refresh(argv):
    name, version = argv
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        base = prepared(name, version, work)
        apply_patch(PATCHES / f"{name}.patch", base)
        shutil.rmtree(VENDOR / name)
        shutil.copytree(base, VENDOR / name)
    print(f"vendor/{name} is now {version} plus vendor/patches/{name}.patch; run cargo update -p {name}")
    return 0


COMMANDS = {"check": check, "generate": generate, "refresh": refresh}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        raise SystemExit("usage: vendor-patches.py check | generate [crate...] | refresh <crate> <version>")
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]))
