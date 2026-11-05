#!/bin/sh
# Installs a Flatpak bundle, as root in a fresh, privileged Ubuntu container
# with nothing set up but Flatpak, so the GNOME runtime has to come from the
# Flathub repository the bundle names. Then checks that the app starts, that
# its desktop entry and metainfo validate, and that the bundle carries the
# catalogue of each language the LINGUAS file names.
# Usage: smoke-test-flatpak.sh <tablepro .flatpak> [<po/LINGUAS>]
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: smoke-test-flatpak.sh <bundle> [<po/LINGUAS>]" >&2
    exit 2
fi
bundle="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
languages=""
if [ $# -eq 2 ]; then
    languages="$(sed 's/#.*//' "$2")"
fi
app=app.tablepro.TablePro

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates flatpak \
    desktop-file-utils appstream xvfb xauth dbus-daemon
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

flatpak install --user --noninteractive "$bundle"
remotes="$(flatpak remotes --user --columns=name,url)"
echo "$remotes"
case "$remotes" in
*https://dl.flathub.org/repo/*) ;;
*)
    echo "smoke-test-flatpak.sh: installing the bundle added no Flathub remote for its runtime" >&2
    exit 1
    ;;
esac

help="$(flatpak run "$app" --help)"
case "$help" in
*--help-gapplication*) ;;
*)
    echo "smoke-test-flatpak.sh: tablepro --help did not list the GApplication options:" >&2
    echo "$help" >&2
    exit 1
    ;;
esac

files="$(flatpak info --user --show-location "$app")/files"
desktop-file-validate "$files/share/applications/$app.desktop"
appstreamcli validate --no-net "$files/share/metainfo/$app.metainfo.xml"
for lang in $languages; do
    if [ ! -f "$files/share/locale/$lang/LC_MESSAGES/tablepro.mo" ]; then
        echo "smoke-test-flatpak.sh: the bundle has no $lang catalogue" >&2
        exit 1
    fi
done

# A window that is still up after the timeout has found its GTK modules,
# icon theme and resources.
status=0
xvfb-run -a dbus-run-session -- timeout 15 flatpak run "$app" || status=$?
if [ "$status" -ne 124 ]; then
    echo "smoke-test-flatpak.sh: tablepro exited with status $status before the 15 second timeout" >&2
    exit 1
fi
echo "smoke-test-flatpak.sh: $(basename "$bundle") installs, starts and validates"
