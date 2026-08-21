#!/usr/bin/env bash
set -euo pipefail

# Generates TablePro.xcodeproj and TableProMobile/TableProMobile.xcodeproj from their
# project.yml specs. Both projects are build artifacts and are not in git; run this
# after cloning, after editing a project.yml or Configs/*.xcconfig, and after adding,
# moving, or deleting a source file.

REQUIRED_XCODEGEN_VERSION="2.46.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
xcodegen generate --quiet --spec project.yml
xcodegen generate --quiet --spec TableProMobile/project.yml --project TableProMobile

echo "Generated TablePro.xcodeproj and TableProMobile/TableProMobile.xcodeproj"
