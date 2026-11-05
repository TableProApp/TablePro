#!/bin/sh
# Installs TablePro from a Flatpak repository flatpak-test-site.sh made, as
# root in a fresh, privileged Ubuntu container with nothing set up but that
# release's own Flatpak. It serves the repository on http://127.0.0.1:8080,
# installs the app from its .flatpakref, which brings the GNOME runtime from
# Flathub, checks that the app starts and carries the catalogue of each
# language the LINGUAS file names, and updates it to the second commit. Then
# it installs the bundle of the first commit in its place, and updates that
# from the repository the bundle names.
# Usage: smoke-test-flatpak.sh <site dir> <stable|beta> [<po/LINGUAS>]
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: smoke-test-flatpak.sh <site dir> <stable|beta> [<po/LINGUAS>]" >&2
    exit 2
fi
site="$(cd "$1" && pwd)"
branch="$2"
languages=""
if [ $# -eq 3 ]; then
    languages="$(sed 's/#.*//' "$3")"
fi
case "$branch" in
stable) dir=repo ;;
beta) dir=beta-repo ;;
*)
    echo "smoke-test-flatpak.sh: the branch is stable or beta, not $branch" >&2
    exit 2
    ;;
esac
app=app.tablepro.TablePro
ref="$app//$branch"
url="http://127.0.0.1:8080/$dir/"

fail() {
    echo "smoke-test-flatpak.sh: $*" >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
# dbus, not dbus-daemon, which Ubuntu 22.04 does not split out.
apt-get install -y --no-install-recommends ca-certificates flatpak python3 xvfb xauth dbus
flatpak --version
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# flatpak run asks the system bus for parental controls, and fails with
# "Could not connect" where there is none.
if [ ! -S /run/dbus/system_bus_socket ]; then
    mkdir -p /run/dbus
    dbus-daemon --system --fork
fi

# The server follows the link, so pointing it at the second repository
# publishes the update.
serve="$(mktemp -d)"
ln -s "$site/one" "$serve/root"
python3 -m http.server --bind 127.0.0.1 --directory "$serve/root" 8080 > "$serve/http.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
python3 - "$url" <<'EOF'
import sys, time, urllib.request
for _ in range(50):
    try:
        urllib.request.urlopen(sys.argv[1] + "summary").close()
        sys.exit(0)
    except OSError:
        time.sleep(0.2)
sys.exit("the repository server did not answer")
EOF

installed_commit() {
    flatpak info --user --show-commit "$ref"
}

check_app() {
    help="$(dbus-run-session -- flatpak run "$ref" --help)"
    case "$help" in
    *--help-gapplication*) ;;
    *) fail "tablepro --help did not list the GApplication options: $help" ;;
    esac
    files="$(flatpak info --user --show-location "$ref")/files"
    for lang in $languages; do
        [ -f "$files/share/locale/$lang/LC_MESSAGES/tablepro.mo" ] || fail "the app has no $lang catalogue"
    done
}

flatpak install --user --noninteractive --from "$url$app.flatpakref"
remotes="$(flatpak remotes --user --columns=name,url)"
echo "$remotes"
case "$remotes" in
*https://dl.flathub.org/repo/*) ;;
*) fail "the .flatpakref added no Flathub remote for the runtime" ;;
esac
check_app
# A window that is still up after the timeout has found its GTK modules,
# icon theme and resources.
status=0
xvfb-run -a dbus-run-session -- timeout 15 flatpak run "$ref" || status=$?
[ "$status" -eq 124 ] || fail "tablepro exited with status $status before the 15 second timeout"

first="$(installed_commit)"
ln -sfn "$site/two" "$serve/root"
flatpak update --user --noninteractive "$ref"
second="$(installed_commit)"
[ "$second" != "$first" ] || fail "flatpak update stayed on $first"
check_app

remote="$(flatpak info --user --show-origin "$ref")"
flatpak uninstall --user --noninteractive "$ref"
flatpak remote-delete --user --force "$remote"
flatpak install --user --noninteractive "$site/bundles/tablepro-$(flatpak --default-arch).flatpak"
[ "$(installed_commit)" = "$first" ] || fail "the bundle installed $(installed_commit), not $first"
origin="$(flatpak info --user --show-origin "$ref")"
flatpak remotes --user --columns=name,url |
    awk -v name="$origin" -v url="$url" '$1 == name && $2 == url { found = 1 } END { exit !found }' ||
    fail "the bundle's remote $origin does not name $url"
flatpak update --user --noninteractive "$ref"
[ "$(installed_commit)" = "$second" ] || fail "the bundle did not update to $second"
check_app
echo "smoke-test-flatpak.sh: $app installs from $url, from its bundle, and updates both ways"
