#!/usr/bin/env bash
set -euo pipefail

# Generates TablePro.xcodeproj and TableProMobile/TableProMobile.xcodeproj from their
# project.yml specs. Both projects are build artifacts and are not in git; run this
# after cloning, after editing a project.yml or Configs/*.xcconfig, and after adding,
# moving, or deleting a source file.
#
# Usage: generate-project.sh [both|macos|ios]
#
# The macOS spec names two files by path, Libs/dylibs/libssl.3.dylib and libcrypto.3.dylib, which
# it copies into the app bundle. XcodeGen validates a named path at generation time, so the macOS
# project cannot be generated before scripts/download-libs.sh has produced them. The iOS job does
# not build the macOS project and has no reason to pay for that, which is why the platform is
# selectable: it generated both, ahead of downloading anything, and every iOS run failed with
# "Target TablePro has a missing source directory".

REQUIRED_XCODEGEN_VERSION="2.46.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-both}"

if ! command -v xcodegen > /dev/null; then
    echo "ERROR: xcodegen is not installed." >&2
    echo "       brew install xcodegen" >&2
    exit 1
fi

installed_version=$(xcodegen --version | awk '{print $2}')
if [ "$installed_version" != "$REQUIRED_XCODEGEN_VERSION" ]; then
    echo "WARNING: xcodegen $installed_version installed, project.yml targets $REQUIRED_XCODEGEN_VERSION." >&2
    echo "         Generated projects may differ from CI. brew upgrade xcodegen" >&2
fi

cd "$REPO_ROOT"

generate_macos() {
    for dylib in libssl.3.dylib libcrypto.3.dylib; do
        [ -f "Libs/dylibs/$dylib" ] && continue
        echo "ERROR: Libs/dylibs/$dylib is missing, and the macOS project copies it into the app bundle." >&2
        echo "       Run scripts/download-libs.sh first; it builds the dylibs from the static libraries." >&2
        exit 1
    done
    xcodegen generate --quiet --spec project.yml
    echo "Generated TablePro.xcodeproj"
}

generate_ios() {
    xcodegen generate --quiet --spec TableProMobile/project.yml --project TableProMobile
    echo "Generated TableProMobile/TableProMobile.xcodeproj"
}

case "$PLATFORM" in
    both) generate_macos; generate_ios ;;
    macos) generate_macos ;;
    ios) generate_ios ;;
    *) echo "ERROR: unknown platform '$PLATFORM'. Use both, macos or ios." >&2; exit 1 ;;
esac
