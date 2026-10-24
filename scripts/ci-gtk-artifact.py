import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def source_identity():
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True
    )
    if status:
        raise ValueError("GTK artifact requires a clean source checkout")
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("GTK artifact must contain a regular binary file")
    if not 0 < path.stat().st_size <= 512 * 1024 * 1024:
        raise ValueError("GTK artifact binary size is outside the supported limit")
    with path.open("rb") as binary:
        return hashlib.file_digest(binary, "sha256").hexdigest()


def create(binary, output, expected_sha):
    if source_identity() != expected_sha:
        raise ValueError("GTK artifact source does not match the requested commit")
    binary_digest = digest(binary)
    if output.is_symlink():
        raise ValueError("GTK artifact output must be a regular directory")
    output.mkdir(parents=True, exist_ok=True)
    for entry in output.iterdir():
        if entry.name not in {"bookie", "manifest.json"} or entry.is_symlink() or not entry.is_file():
            raise ValueError("GTK artifact output contains an unexpected file")
    destination = output / "bookie"
    shutil.copyfile(binary, destination)
    destination.chmod(0o644)
    manifest = {
        "schema_version": 1,
        "source_commit": expected_sha,
        "architecture": platform.machine(),
        "profile": "ci",
        "sha256": binary_digest,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")
    return output


def verify(directory, expected_sha):
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > 4096:
        raise ValueError("GTK artifact requires a small regular manifest")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ValueError("GTK artifact manifest version is unsupported")
    if manifest.get("source_commit") != expected_sha:
        raise ValueError("GTK artifact source does not match the requested commit")
    if manifest.get("architecture") != platform.machine():
        raise ValueError("GTK artifact architecture does not match this worker")
    if manifest.get("profile") != "ci":
        raise ValueError("GTK artifact profile must be ci")
    binary = directory / "bookie"
    if digest(binary) != manifest.get("sha256"):
        raise ValueError("GTK artifact digest does not match its manifest")
    binary.chmod(0o755)
    return binary.resolve()


def main():
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    publish = subcommands.add_parser("create")
    publish.add_argument("binary", type=Path)
    publish.add_argument("directory", type=Path)
    publish.add_argument("source_commit")
    consume = subcommands.add_parser("verify")
    consume.add_argument("directory", type=Path)
    consume.add_argument("source_commit")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
            raise ValueError("GTK artifact requires a full source commit")
        if args.command == "create":
            result = create(args.binary, args.directory, args.source_commit)
        else:
            if source_identity() != args.source_commit:
                raise ValueError("GTK artifact source does not match this checkout")
            result = verify(args.directory, args.source_commit)
        print(result)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"GTK artifact refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
