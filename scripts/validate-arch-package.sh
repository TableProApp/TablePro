#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/tablepro.pkg.tar.zst" >&2
  exit 2
fi
package="$1"
if [[ ! -f "$package" ]]; then
  echo "package not found: $package" >&2
  exit 2
fi

contents="$(bsdtar -tf "$package")"
for required in \
  usr/bin/bookie \
  usr/bin/bookie-agentd \
  usr/bin/tablepro-askpass \
  usr/bin/tablepro \
  usr/bin/tablepro-agentd \
  usr/share/glib-2.0/schemas/com.tablepro.linux.gschema.xml \
  usr/share/applications/com.tablepro.linux.desktop \
  usr/share/metainfo/com.tablepro.linux.metainfo.xml \
  usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg \
  usr/share/licenses/bookie/LICENSE.md \
  usr/share/doc/bookie/BUILD_INPUTS.json \
  usr/share/licenses/bookie/THIRD_PARTY_NOTICES.md \
  usr/share/doc/bookie/policy.example.toml; do
  if ! grep -Fxq "$required" <<<"$contents"; then
    echo "package is missing $required" >&2
    exit 1
  fi
done
if grep -Fq 'tablepro-agentd.service' <<<"$contents"; then
  echo "the internal RC must not ship the obsolete agentd systemd unit" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
bsdtar -xf "$package" -C "$stage"
python3 - "$stage/usr/share/doc/bookie/BUILD_INPUTS.json" "$(basename "$package")" <<'PY'
from datetime import date
import json
from pathlib import Path
import re
import sys

metadata = json.loads(Path(sys.argv[1]).read_text())
package_name = sys.argv[2]
match = re.fullmatch(r"bookie-([0-9]+\.[0-9]+\.[0-9]+(?:[a-z]+[0-9]+)?)-[0-9]+-x86_64\.pkg\.tar\.(?:zst|xz)", package_name)
if not match:
    raise SystemExit(f"unexpected Arch package filename: {package_name}")
if metadata.get("package_version") != match.group(1) or metadata.get("source_version") != match.group(1):
    raise SystemExit("package and recorded source versions do not match")
if metadata.get("target") != "x86_64-unknown-linux-gnu":
    raise SystemExit("release input target does not match the Arch package architecture")
if not re.fullmatch(r"[0-9a-f]{40}", metadata.get("commit", "")):
    raise SystemExit("release input commit is not an immutable SHA")
for key in ("source_archive_sha256", "vendor_archive_sha256", "arch_recipe_sha256"):
    if not re.fullmatch(r"[0-9a-f]{64}", metadata.get(key, "")):
        raise SystemExit(f"invalid {key}")
date.fromisoformat(metadata.get("release_date", ""))
for key in ("cargo", "rustc"):
    if not isinstance(metadata.get(key), str) or not metadata[key]:
        raise SystemExit(f"missing {key} version")
native_inputs = metadata.get("native_build_inputs")
if not isinstance(native_inputs, dict):
    raise SystemExit("missing native build inputs")
for key in ("depends", "makedepends", "checkdepends"):
    values = native_inputs.get(key)
    if not isinstance(values, list) or not values or any(not isinstance(value, str) for value in values):
        raise SystemExit(f"invalid native {key}")
PY
desktop-file-validate "$stage/usr/share/applications/com.tablepro.linux.desktop"
appstreamcli validate --no-net "$stage/usr/share/metainfo/com.tablepro.linux.metainfo.xml"
agent_help="$("$stage/usr/bin/tablepro-agentd" --help)"
if grep -Eq -- '--transport|loopback HTTP|http transport' <<<"$agent_help"; then
  echo "the packaged agentd must remain an on-demand stdio-only process" >&2
  exit 1
fi
