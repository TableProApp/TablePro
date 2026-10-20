#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${TABLEPRO_RC_TAG:-}"
remote="${TABLEPRO_RC_REMOTE:-https://github.com/cozyGarage/BookiE.git}"
version="${TABLEPRO_RC_VERSION:?Set TABLEPRO_RC_VERSION to the candidate package version}"
release_date="${TABLEPRO_RC_DATE:?Set TABLEPRO_RC_DATE to the candidate release date (YYYY-MM-DD)}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-z]+[0-9]+)?$ ]]; then
  echo "invalid candidate version: $version (use e.g. 0.2.0 or 0.2.0rc1)" >&2
  exit 1
fi
if [[ ! "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
   [[ "$(date -d "$release_date" +%F 2>/dev/null || true)" != "$release_date" ]]; then
  echo "invalid candidate release date: $release_date (use YYYY-MM-DD)" >&2
  exit 1
fi
source_version="$(python3 - "$root" <<'PY'
from pathlib import Path
import sys
import tomllib

root = Path(sys.argv[1])
def package_version(manifest):
    version = tomllib.loads((root / manifest).read_text())["package"]["version"]
    if isinstance(version, dict) and version.get("workspace") is True:
        return tomllib.loads((root / "Cargo.toml").read_text())["workspace"]["package"]["version"]
    return version

versions = {package_version(manifest) for manifest in ("apps/linux/app/Cargo.toml", "crates/agentd/Cargo.toml")}
if len(versions) != 1:
    raise SystemExit("app and agentd package versions differ")
print(versions.pop())
PY
)"
if [[ "$version" != "$source_version" ]]; then
  echo "candidate package version $version does not match app and agentd source version $source_version" >&2
  exit 1
fi
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "refusing to package a dirty tree; commit and validate the RC candidate first" >&2
  exit 1
fi
if [[ -n "${TABLEPRO_RC_COMMIT:-}" && -n "$tag" ]]; then
  echo "set TABLEPRO_RC_COMMIT or TABLEPRO_RC_TAG, not both" >&2
  exit 1
fi
if [[ -n "$tag" ]]; then
  commit="$(git -C "$root" rev-parse --verify "refs/tags/$tag^{commit}")"
  remote_refs="$(git ls-remote --tags "$remote" "refs/tags/$tag" "refs/tags/$tag^{}")"
  remote_commit="$(awk '$2 ~ /\^\{\}$/ { print $1; found=1; exit } END { if (!found && NR == 1) print first } NR == 1 { first=$1 }' <<<"$remote_refs")"
  if [[ "$remote_commit" != "$commit" ]]; then
    echo "remote RC tag $tag does not resolve to local commit $commit" >&2
    exit 1
  fi
else
  candidate="${TABLEPRO_RC_COMMIT:?Set TABLEPRO_RC_COMMIT to the full candidate SHA (no published tag needed)}"
  if [[ ! "$candidate" =~ ^[0-9a-f]{40}$ ]]; then
    echo "candidate must be a full immutable commit SHA" >&2
    exit 1
  fi
  commit="$(git -C "$root" rev-parse --verify "$candidate^{commit}")"
fi
if [[ "$commit" != "$(git -C "$root" rev-parse HEAD)" ]]; then
  echo "candidate does not identify the checked-out commit" >&2
  exit 1
fi

output_dir="${TABLEPRO_RC_OUTPUT_DIR:-$root/target/arch-release-inputs}"
mkdir -p "$output_dir"
archive_dir="$(mktemp -d "$output_dir/.build.XXXXXX")"
trap 'rm -rf -- "$archive_dir"' EXIT
archive="$output_dir/bookie-$version-$commit.tar.gz"
git -C "$root" archive --format=tar.gz --prefix="TablePro-$commit/" "$commit" > "$archive"
checksum="$(sha256sum "$archive" | awk '{print $1}')"
vendor_tree="$archive_dir/TablePro-$commit"
vendor_dir="$vendor_tree/cargo-vendor"
mkdir -p "$vendor_dir" "$vendor_tree/.cargo"
cargo fetch --locked --manifest-path "$root/apps/linux/app/Cargo.toml"
cargo fetch --locked --manifest-path "$root/crates/agentd/Cargo.toml"
cargo fetch --locked --manifest-path "$root/crates/ssh/Cargo.toml"
cargo vendor --manifest-path "$root/apps/linux/app/Cargo.toml" \
  --sync "$root/crates/agentd/Cargo.toml" --sync "$root/crates/ssh/Cargo.toml" \
  --locked --offline --versioned-dirs "$vendor_dir" > "$archive_dir/cargo-vendor-config.toml"
python3 - "$archive_dir/cargo-vendor-config.toml" "$vendor_tree/.cargo/config.toml" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
lines = [
    'directory = "cargo-vendor"' if line.lstrip().startswith("directory = ") else line
    for line in source.splitlines()
]
if not any(line == 'directory = "cargo-vendor"' for line in lines):
    raise SystemExit("cargo vendor did not emit a directory source")
Path(sys.argv[2]).write_text("\n".join(lines) + "\n")
PY
vendor_archive="$output_dir/bookie-vendor-$version-$commit.tar.gz"
tar -C "$archive_dir" -czf "$vendor_archive" "TablePro-$commit/.cargo" "TablePro-$commit/cargo-vendor"
vendor_checksum="$(sha256sum "$vendor_archive" | awk '{print $1}')"
metadata="$output_dir/bookie-$version-$commit-inputs.json"
pkbuild_checksum="$(sha256sum "$root/apps/linux/packaging/arch/PKGBUILD" | awk '{print $1}')"
TABLEPRO_METADATA_PATH="$metadata" TABLEPRO_SOURCE_SHA256="$checksum" \
TABLEPRO_VENDOR_SHA256="$vendor_checksum" TABLEPRO_SOURCE_VERSION="$source_version" \
TABLEPRO_PACKAGE_VERSION="$version" TABLEPRO_RELEASE_DATE="$release_date" \
TABLEPRO_PKGBUILD_SHA256="$pkbuild_checksum" \
TABLEPRO_PKGBUILD_PATH="$root/apps/linux/packaging/arch/PKGBUILD" \
TABLEPRO_COMMIT="$commit" TABLEPRO_TAG="$tag" \
TABLEPRO_TARGET="${CARCH:-x86_64}-unknown-linux-gnu" \
TABLEPRO_CARGO_VERSION="$(cargo --version)" TABLEPRO_RUSTC_VERSION="$(rustc --version)" \
python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import shlex

recipe = Path(os.environ["TABLEPRO_PKGBUILD_PATH"]).read_text()
native_inputs = {}
for name in ("depends", "makedepends", "checkdepends"):
    match = re.search(rf"(?m)^{name}=\(([^)]*)\)", recipe)
    if not match:
        raise SystemExit(f"PKGBUILD has no {name} array")
    native_inputs[name] = shlex.split(match.group(1))
metadata = {
    "commit": os.environ["TABLEPRO_COMMIT"],
    "tag": os.environ["TABLEPRO_TAG"] or None,
    "source_version": os.environ["TABLEPRO_SOURCE_VERSION"],
    "package_version": os.environ["TABLEPRO_PACKAGE_VERSION"],
    "release_date": os.environ["TABLEPRO_RELEASE_DATE"],
    "target": os.environ["TABLEPRO_TARGET"],
    "cargo": os.environ["TABLEPRO_CARGO_VERSION"],
    "rustc": os.environ["TABLEPRO_RUSTC_VERSION"],
    "source_archive_sha256": os.environ["TABLEPRO_SOURCE_SHA256"],
    "vendor_archive_sha256": os.environ["TABLEPRO_VENDOR_SHA256"],
    "arch_recipe_sha256": os.environ["TABLEPRO_PKGBUILD_SHA256"],
    "workspace_roots": ["tablepro-app:kerberos", "tablepro-agentd:kerberos", "tablepro-ssh:tablepro-askpass"],
    "native_build_inputs": native_inputs,
}
Path(os.environ["TABLEPRO_METADATA_PATH"]).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY
metadata_checksum="$(sha256sum "$metadata" | awk '{print $1}')"

cd "$root/apps/linux/packaging/arch"
export TABLEPRO_RC_COMMIT="$commit"
export TABLEPRO_RC_SHA256="$checksum"
export TABLEPRO_RC_VERSION="$version"
export TABLEPRO_RC_ARCHIVE="$archive"
export TABLEPRO_RC_VENDOR_ARCHIVE="$vendor_archive"
export TABLEPRO_RC_VENDOR_SHA256="$vendor_checksum"
export TABLEPRO_RC_METADATA="$metadata"
export TABLEPRO_RC_METADATA_SHA256="$metadata_checksum"
export TABLEPRO_RC_DATE="$release_date"
export SRCDEST="$output_dir"
makepkg --cleanbuild --clean ${TABLEPRO_RC_MAKEPKG_DEPS:---syncdeps} --noconfirm
mapfile -t package_files < <(makepkg --packagelist)
namcap PKGBUILD "${package_files[@]}"
validated=0
for package_file in "${package_files[@]}"; do
  # Arch may emit a separate debug package; only the application package
  # contains desktop metadata and executables required by our validator.
  if [[ "$(basename "$package_file")" == bookie-"$version"-* ]]; then
    "$root/scripts/validate-arch-package.sh" "$package_file"
    sha256sum "$package_file"
    validated=$((validated + 1))
  fi
done
if [[ "$validated" != 1 ]]; then
  echo "expected exactly one BookiE application package, found $validated" >&2
  exit 1
fi
