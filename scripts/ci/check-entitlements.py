#!/usr/bin/env python3
"""Check both apps pin the Production CloudKit environment.

A signed build without the key talks to Development, which the shipped schema never reaches.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

KEY = "com.apple.developer.icloud-container-environment"
ENTITLEMENTS = (
    "TablePro/TablePro.entitlements",
    "TableProMobile/TableProMobile/TableProMobileRelease.entitlements",
)


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    status = 0
    for relative in ENTITLEMENTS:
        value = plistlib.loads((root / relative).read_bytes()).get(KEY)
        if value != "Production":
            print(f"{relative}: {KEY} is {value!r}, expected 'Production'")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
