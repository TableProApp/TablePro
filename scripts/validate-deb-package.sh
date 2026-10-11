#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/tablepro.deb" >&2
  exit 2
fi
package="$1"
if [[ ! -f "$package" ]]; then
  echo "package not found: $package" >&2
  exit 2
fi

control="$(dpkg-deb -I "$package")"
if ! grep -Eq '^[[:space:]]*Package: tablepro$' <<<"$control"; then
  echo "Debian package name must remain tablepro" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*Version: 0\.1\.5-1$' <<<"$control"; then
  echo "Debian package version must be 0.1.5-1" >&2
  exit 1
fi

package_contents="$(dpkg-deb -c "$package")"
if grep -Fq 'tablepro-agentd.service' <<<"$package_contents"; then
  echo "the Debian package must not ship the obsolete agentd systemd unit" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
dpkg-deb -x "$package" "$stage"
for required in \
  usr/bin/bookie \
  usr/bin/bookie-agentd \
  usr/bin/tablepro \
  usr/bin/tablepro-agentd \
  usr/bin/tablepro-askpass \
  usr/share/applications/com.tablepro.linux.desktop \
  usr/share/metainfo/com.tablepro.linux.metainfo.xml \
  usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg \
  usr/share/glib-2.0/schemas/com.tablepro.linux.gschema.xml \
  usr/share/doc/tablepro/LICENSE.md \
  usr/share/doc/tablepro/policy.example.toml; do
  if [[ ! -e "$stage/$required" ]]; then
    echo "package is missing /$required" >&2
    exit 1
  fi
done
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$stage/usr/share/applications/com.tablepro.linux.desktop"
fi
if command -v appstreamcli >/dev/null 2>&1; then
  appstreamcli validate --no-net "$stage/usr/share/metainfo/com.tablepro.linux.metainfo.xml"
fi
if [[ "$(readlink "$stage/usr/bin/tablepro")" != bookie ]]; then
  echo "usr/bin/tablepro must be a symlink to bookie" >&2
  exit 1
fi
if [[ "$(readlink "$stage/usr/bin/tablepro-agentd")" != bookie-agentd ]]; then
  echo "usr/bin/tablepro-agentd must be a symlink to bookie-agentd" >&2
  exit 1
fi
if ! grep -Fxq 'Exec=bookie' "$stage/usr/share/applications/com.tablepro.linux.desktop"; then
  echo "desktop file must launch bookie" >&2
  exit 1
fi
agent_help="$("$stage/usr/bin/bookie-agentd" --help)"
if grep -Eq -- '--transport|loopback HTTP|http transport' <<<"$agent_help"; then
  echo "the packaged agentd must remain an on-demand stdio-only process" >&2
  exit 1
fi
