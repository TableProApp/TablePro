#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <released.pkg.tar.zst> <new.pkg.tar.zst>" >&2
  exit 2
fi
released=$(realpath "$1")
candidate=$(realpath "$2")
config="${XDG_CONFIG_HOME:-$HOME/.config}/tablepro"
data="${XDG_DATA_HOME:-$HOME/.local/share}/tablepro"

if [ -e "$config/connections.json" ] || [ -e "$data/history.db" ]; then
  echo "refusing to run over existing user data in $config or $data" >&2
  exit 1
fi
mkdir -p "$config" "$data"
echo keep > "$config/connections.json"
echo keep > "$data/history.db"
cleanup() {
  rm -f "$config/connections.json" "$data/history.db"
  sudo pacman -R --noconfirm bookie >/dev/null 2>&1 || true
}
trap cleanup EXIT

keeps_user_data() {
  test "$(cat "$config/connections.json")" = keep
  test "$(cat "$data/history.db")" = keep
}

"$(dirname "$0")/validate-arch-package.sh" "$candidate"
sudo pacman -U --noconfirm "$released" >/dev/null
keeps_user_data
released_version=$(pacman -Q bookie)
sudo pacman -U --noconfirm "$candidate" >/dev/null
upgraded_version=$(pacman -Q bookie)
test "$released_version" != "$upgraded_version"
test -x /usr/bin/bookie && test -x /usr/bin/bookie-agentd
keeps_user_data
sudo pacman -R --noconfirm bookie >/dev/null
test ! -e /usr/bin/bookie
keeps_user_data
echo "upgrade from $released_version to $upgraded_version and removal keep the user data"
