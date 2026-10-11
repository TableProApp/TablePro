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
desktop-file-validate "$stage/usr/share/applications/com.tablepro.linux.desktop"
appstreamcli validate --no-net "$stage/usr/share/metainfo/com.tablepro.linux.metainfo.xml"
agent_help="$("$stage/usr/bin/tablepro-agentd" --help)"
if grep -Eq -- '--transport|loopback HTTP|http transport' <<<"$agent_help"; then
  echo "the packaged agentd must remain an on-demand stdio-only process" >&2
  exit 1
fi
