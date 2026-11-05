#!/bin/sh
# Installs TablePro from the Flatpak repositories flatpak-test-site.sh made,
# as root in a fresh, privileged Ubuntu container with nothing set up but that
# release's own Flatpak, serving them on http://127.0.0.1:8080. It installs
# the release from its .flatpakref, which brings the GNOME runtime from
# Flathub, checks that it starts and carries the catalogue of each language
# the LINGUAS file names, updates it to the second commit, and installs its
# .Debug extension. It installs the beta beside it and switches which of the
# two the app's name starts, keeping one set of data. Last it installs the
# bundle of the first commit in place of the release, and updates that from
# the repository the bundle names.
# Usage: smoke-test-flatpak.sh <site dir> [<po/LINGUAS>]
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: smoke-test-flatpak.sh <site dir> [<po/LINGUAS>]" >&2
    exit 2
fi
site="$(cd "$1" && pwd)"
languages=""
if [ $# -eq 2 ]; then
    languages="$(sed 's/#.*//' "$2")"
fi
app=app.tablepro.TablePro
stable="$app//stable"
beta="$app//beta"
server=http://127.0.0.1:8080

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

# The server follows the link, so pointing it at the second commit publishes
# the update.
serve="$(mktemp -d)"
ln -s "$site/one" "$serve/root"
python3 -m http.server --bind 127.0.0.1 --directory "$serve/root" 8080 > "$serve/http.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
python3 - "$server/repo/summary" <<'EOF'
import sys, time, urllib.request
for _ in range(50):
    try:
        urllib.request.urlopen(sys.argv[1]).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.2)
sys.exit("the repository server did not answer")
EOF

commit_of() {
    flatpak info --user --show-commit "$1"
}

in_app() {
    ref="$1"
    shift
    dbus-run-session -- flatpak run --command=sh "$ref" -c "$@"
}

check_app() {
    help="$(dbus-run-session -- flatpak run "$1" --help)"
    case "$help" in
    *--help-gapplication*) ;;
    *) fail "$1 --help did not list the GApplication options: $help" ;;
    esac
    files="$(flatpak info --user --show-location "$1")/files"
    for lang in $languages; do
        [ -f "$files/share/locale/$lang/LC_MESSAGES/tablepro.mo" ] || fail "$1 has no $lang catalogue"
    done
}

# The branch the app's name starts, from the instance's own record.
current_branch() {
    in_app "$app" 'sed -n "s/^branch=//p" /.flatpak-info'
}

flatpak install --user --noninteractive --from "$server/repo/$app.flatpakref"
remotes="$(flatpak remotes --user --columns=name,url)"
echo "$remotes"
case "$remotes" in
*https://dl.flathub.org/repo/*) ;;
*) fail "the .flatpakref added no Flathub remote for the runtime" ;;
esac
check_app "$stable"
# A window that is still up after the timeout has found its GTK modules,
# icon theme and resources.
status=0
xvfb-run -a dbus-run-session -- timeout 15 flatpak run "$stable" || status=$?
[ "$status" -eq 124 ] || fail "tablepro exited with status $status before the 15 second timeout"
# shellcheck disable=SC2016 # the sandbox's shell expands it
in_app "$stable" 'touch "$XDG_CONFIG_HOME/smoke-test"'

first="$(commit_of "$stable")"
ln -sfn "$site/two" "$serve/root"
flatpak update --user --noninteractive "$stable"
second="$(commit_of "$stable")"
[ "$second" != "$first" ] || fail "flatpak update stayed on $first"
check_app "$stable"

remote="$(flatpak info --user --show-origin "$stable")"
flatpak install --user --noninteractive "$remote" "$app.Debug//stable"
debug="$(flatpak info --user --show-location "$app.Debug//stable")/files"
find "$debug" -name '*.debug' | grep -q . || fail "the .Debug extension holds no debug file"

flatpak install --user --noninteractive --from "$server/beta-repo/$app.flatpakref"
check_app "$beta"
flatpak make-current --user "$app" beta
[ "$(current_branch)" = beta ] || fail "make-current beta left $(current_branch) current"
# shellcheck disable=SC2016 # the sandbox's shell expands it
in_app "$beta" 'test -f "$XDG_CONFIG_HOME/smoke-test"' || fail "the beta does not see the release's data"
flatpak make-current --user "$app" stable
[ "$(current_branch)" = stable ] || fail "make-current stable left $(current_branch) current"
flatpak uninstall --user --noninteractive "$beta"
[ "$(current_branch)" = stable ] || fail "uninstalling the beta left $(current_branch) current"

flatpak uninstall --user --noninteractive "$app.Debug//stable" "$stable"
flatpak remote-delete --user --force "$remote"
flatpak install --user --noninteractive "$site/bundles/stable/tablepro-$(flatpak --default-arch).flatpak"
[ "$(commit_of "$stable")" = "$first" ] || fail "the bundle installed $(commit_of "$stable"), not $first"
origin="$(flatpak info --user --show-origin "$stable")"
flatpak remotes --user --columns=name,url |
    awk -v name="$origin" -v url="$server/repo/" '$1 == name && $2 == url { found = 1 } END { exit !found }' ||
    fail "the bundle's remote $origin does not name $server/repo/"
flatpak update --user --noninteractive "$stable"
[ "$(commit_of "$stable")" = "$second" ] || fail "the bundle did not update to $second"
check_app "$stable"
# shellcheck disable=SC2016 # the sandbox's shell expands it
in_app "$stable" 'test -f "$XDG_CONFIG_HOME/smoke-test"' || fail "the bundle does not see the earlier data"
echo "smoke-test-flatpak.sh: $app installs, updates and switches channels from $server"
