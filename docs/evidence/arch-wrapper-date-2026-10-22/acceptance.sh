#!/usr/bin/env bash
set -euo pipefail
printf 'Installing isolated package-test dependencies\n'
pacman -Syu --noconfirm --needed sudo python desktop-file-utils appstream gtk4 libadwaita gtksourceview5 libsecret krb5 sqlite openssl > /tmp/pacman.log 2>&1 || { cat /tmp/pacman.log; exit 1; }
useradd -m builder
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
pacman -Q gtk4 glib2 libadwaita gtksourceview5
for kind in config data; do
  case "$kind" in
    config) file=$HOME/refusal/config/tablepro/connections.json;;
    data) file=$HOME/refusal/data/tablepro/history.db;;
  esac
  sudo -H -u builder mkdir -p "$(dirname "$file")"
  printf 'existing-user-data\n' | sudo -H -u builder tee "$file" >/dev/null
  before="$(sha256sum "$file")"
  if sudo -H -u builder env XDG_CONFIG_HOME=$HOME/refusal/config XDG_DATA_HOME=$HOME/refusal/data \
      bash /scripts/test-arch-package.sh /packages/released/bookie-0.1.5-1-x86_64.pkg.tar.zst /packages/candidate/bookie-0.2.0-1-x86_64.pkg.tar.zst > /tmp/refusal.log 2>&1; then
    cat /tmp/refusal.log
    exit 1
  fi
  grep -q 'refusing to run over existing user data' /tmp/refusal.log
  test "$(sha256sum "$file")" = "$before"
  ! pacman -Q bookie >/dev/null 2>&1
  sudo -H -u builder rm "$file"
  printf 'Existing %s data refusal preserved\n' "$kind"
done
sudo -H -u builder env XDG_CONFIG_HOME=$HOME/acceptance/config XDG_DATA_HOME=$HOME/acceptance/data \
  bash /scripts/test-arch-package.sh /packages/released/bookie-0.1.5-1-x86_64.pkg.tar.zst /packages/candidate/bookie-0.2.0-1-x86_64.pkg.tar.zst
! pacman -Q bookie >/dev/null 2>&1
test ! -e $HOME/acceptance/config/tablepro/connections.json
test ! -e $HOME/acceptance/data/tablepro/history.db
printf 'Package removal and fixture cleanup verified\n'
