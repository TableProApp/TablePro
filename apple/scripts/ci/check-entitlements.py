#!/usr/bin/env python3
"""Check both apps pin the Production CloudKit environment and can receive CloudKit's change notices.

A signed build without the environment key talks to Development, which the shipped schema never reaches.
A build without the push key never hears of another device's change. The iOS file holds the development
value Xcode writes, and the App Store export signs it as production.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"
EXPECTED = (
    ("TablePro/TablePro.entitlements", ENVIRONMENT_KEY, "Production"),
    ("TablePro/TablePro.entitlements", "com.apple.developer.aps-environment", "production"),
    ("TableProMobile/TableProMobile/TableProMobileRelease.entitlements", ENVIRONMENT_KEY, "Production"),
    ("TableProMobile/TableProMobile/TableProMobileRelease.entitlements", "aps-environment", "development"),
)


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    status = 0
    for relative, key, expected in EXPECTED:
        value = plistlib.loads((root / relative).read_bytes()).get(key)
        if value != expected:
            print(f"{relative}: {key} is {value!r}, expected {expected!r}")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
