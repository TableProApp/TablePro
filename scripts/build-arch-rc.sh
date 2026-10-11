#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${TABLEPRO_RC_TAG:-}"
remote="${TABLEPRO_RC_REMOTE:-https://github.com/cozygarage/TablePro.git}"
version="${TABLEPRO_RC_VERSION:?Set TABLEPRO_RC_VERSION to the candidate package version}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-z]+[0-9]+)?$ ]]; then
  echo "invalid candidate version: $version (use e.g. 0.1.1 or 0.1.1rc1)" >&2
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

archive_dir="$(mktemp -d)"
trap 'rm -rf -- "$archive_dir"' EXIT
archive="$archive_dir/bookie-$version.tar.gz"
git -C "$root" archive --format=tar.gz --prefix="TablePro-$commit/" "$commit" > "$archive"
checksum="$(sha256sum "$archive" | awk '{print $1}')"

cd "$root/packaging/arch"
export TABLEPRO_RC_COMMIT="$commit"
export TABLEPRO_RC_SHA256="$checksum"
export TABLEPRO_RC_VERSION="$version"
export TABLEPRO_RC_ARCHIVE="$archive"
export SRCDEST="$archive_dir"
makepkg --cleanbuild --clean --syncdeps --noconfirm
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
