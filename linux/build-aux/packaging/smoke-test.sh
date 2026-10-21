#!/bin/sh
# Installs a built package, as root in a fresh Ubuntu or Fedora container,
# with only the dependencies it declares, and checks that it starts, that
# the files it installed validate, and that it reads each catalogue: those
# the LINGUAS file of the package's source names, or without one, those the
# package installed.
# Usage: smoke-test.sh <tablepro .deb or .rpm> [<po/LINGUAS>]
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: smoke-test.sh <package> [<po/LINGUAS>]" >&2
    exit 2
fi
package="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
linguas=""
if [ $# -eq 2 ]; then
    linguas="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi

case "$package" in
*.deb)
    export DEBIAN_FRONTEND=noninteractive
    # The Ubuntu image skips every .mo dpkg unpacks; a desktop install keeps them.
    if [ -f /etc/dpkg/dpkg.cfg.d/excludes ]; then
        sed -i '\|^path-exclude=/usr/share/locale/|d' /etc/dpkg/dpkg.cfg.d/excludes
    fi
    apt-get update
    apt-get install -y --no-install-recommends "$package"
    tools="desktop-file-utils appstream libglib2.0-bin xvfb xauth dbus-daemon locales gettext-base"
    install_tools() {
        # shellcheck disable=SC2086 # one word per package
        apt-get install -y --no-install-recommends $tools
        localedef -i en_US -f UTF-8 en_US.UTF-8
    }
    ;;
*.rpm)
    # The Fedora image installs en_US translations only; a desktop install takes all of them.
    rm -f /etc/rpm/macros.image-language-conf
    dnf install -y --setopt=install_weak_deps=False "$package"
    tools="desktop-file-utils appstream xorg-x11-server-Xvfb xorg-x11-xauth dbus-daemon glibc-langpack-en gettext-runtime"
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

# glibc loads no catalogue under C or C.UTF-8, so LANGUAGE picks each
# language under a real locale. The --new-window help text is the app's
# own string, so finding its translation shows the app read the catalogue.
if [ -n "$linguas" ]; then
    languages="$(sed 's/#.*//' "$linguas")"
else
    languages="$(find /usr/share/locale -path '*/LC_MESSAGES/tablepro.mo' | cut -d/ -f5)"
fi
for lang in $languages; do
    if [ ! -f "/usr/share/locale/$lang/LC_MESSAGES/tablepro.mo" ]; then
        echo "smoke-test.sh: the package installed no $lang catalogue" >&2
        exit 1
    fi
    expected="$(LC_ALL=en_US.UTF-8 LANGUAGE="$lang" gettext -d tablepro "Open a new window")"
    if [ "$expected" = "Open a new window" ]; then
        echo "smoke-test.sh: the $lang catalogue does not translate \"Open a new window\"" >&2
        exit 1
    fi
    translated="$(LC_ALL=en_US.UTF-8 LANGUAGE="$lang" tablepro --help)"
    if ! printf '%s\n' "$translated" | grep -qF -- "$expected"; then
        echo "smoke-test.sh: tablepro --help under $lang did not show \"$expected\":" >&2
        echo "$translated" >&2
        exit 1
    fi
done

# A window that is still up after the timeout has found its GTK modules,
# icon theme and resources.
status=0
xvfb-run -a dbus-run-session -- timeout 15 tablepro || status=$?
if [ "$status" -ne 124 ]; then
    echo "smoke-test.sh: tablepro exited with status $status before the 15 second timeout" >&2
    exit 1
fi
echo "smoke-test.sh: $(basename "$package") installs, starts and validates"
