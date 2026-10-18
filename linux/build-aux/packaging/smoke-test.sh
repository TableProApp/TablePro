#!/bin/sh
# Installs a built package, as root in a fresh Ubuntu or Fedora container,
# with only the dependencies it declares, and checks that it starts and
# that the files it installed validate.
# Usage: smoke-test.sh <tablepro .deb or .rpm>
set -eu

if [ $# -ne 1 ]; then
    echo "usage: smoke-test.sh <package>" >&2
    exit 2
fi
package="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

case "$package" in
*.deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$package"
    tools="desktop-file-utils appstream libglib2.0-bin xvfb xauth dbus-daemon"
    install_tools() {
        # shellcheck disable=SC2086 # one word per package
        apt-get install -y --no-install-recommends $tools
    }
    ;;
*.rpm)
    dnf install -y --setopt=install_weak_deps=False "$package"
    tools="desktop-file-utils appstream xorg-x11-server-Xvfb xorg-x11-xauth dbus-daemon"
    install_tools() {
        # shellcheck disable=SC2086 # one word per package
        dnf install -y --setopt=install_weak_deps=False $tools
    }
    ;;
*)
    echo "smoke-test.sh: $package is neither a .deb nor an .rpm" >&2
    exit 2
    ;;
esac

# Before anything else is installed, so the package's own dependencies are
# all it has. The binary opens its settings before it reads the command
# line, so this also proves the schema was installed and compiled.
help="$(tablepro --help)"
case "$help" in
*--help-gapplication*) ;;
*)
    echo "smoke-test.sh: tablepro --help did not list the GApplication options:" >&2
    echo "$help" >&2
    exit 1
    ;;
esac
test -x /usr/libexec/tablepro-askpass

install_tools
desktop-file-validate /usr/share/applications/app.tablepro.TablePro.desktop
appstreamcli validate --no-net /usr/share/metainfo/app.tablepro.TablePro.metainfo.xml
glib-compile-schemas --strict --dry-run /usr/share/glib-2.0/schemas

# A window that is still up after the timeout has found its GTK modules,
# icon theme and resources.
status=0
xvfb-run -a dbus-run-session -- timeout 15 tablepro || status=$?
if [ "$status" -ne 124 ]; then
    echo "smoke-test.sh: tablepro exited with status $status before the 15 second timeout" >&2
    exit 1
fi
echo "smoke-test.sh: $(basename "$package") installs, starts and validates"
