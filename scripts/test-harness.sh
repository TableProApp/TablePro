#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 scripts/inventory-ignored-tests.py --check
python3 scripts/check-gtk-blocking.py
python3 scripts/check-doc-links.py
python3 scripts/check-doc-symbols.py
python3 scripts/update-translations.py --check
python3 scripts/check-moved-paths.py
python3 scripts/check-known-issues.py
python3 scripts/check-release-version.py
if [ -z "${CARGO_ABOUT:-}" ]; then
  CARGO_ABOUT="$(scripts/ensure-cargo-about.sh)"
  export CARGO_ABOUT
fi
python3 scripts/update-third-party-notices.py --check
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/tests/test_arch_candidate.py
python3 scripts/tests/test_deb_package.py
