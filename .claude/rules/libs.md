---
paths:
  - "Libs/**/*"
  - "scripts/download-libs.sh"
  - "scripts/publish-libs.sh"
  - "scripts/publish-ios-libs.sh"
---

# Static libraries

- **`Libs/` is published only through `scripts/publish-libs.sh <rebuilt libs...>`** (and `scripts/publish-ios-libs.sh` for the iOS xcframeworks), then the updated `checksums.sha256` is committed. Never regenerate a checksum file by hand: a stale `Libs/` silently reverts other libraries.
- **`scripts/download-libs.sh` verifies every archive against the checksums**; `--force` re-downloads.
