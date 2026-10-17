---
paths:
  - "Libs/**/*"
  - "scripts/download-libs.sh"
  - "scripts/publish-libs.sh"
---

# Static libraries

- **`Libs/` is published only through `scripts/publish-libs.sh <rebuilt .a or .xcframework...>`.** Each run creates the next immutable `libs-<n>` release and writes `Libs/release` and both `checksums.sha256` files, which are committed together. Never edit them by hand: a stale `Libs/` silently reverts other libraries.
- A published `libs-<n>` never changes; a fix is the next `<n>`. `libs-v1` stays frozen for older commits.
- **`scripts/download-libs.sh` fetches the release `Libs/release` names at `HEAD` and verifies every file against the checksums at `HEAD`** on every run; `--force` re-downloads.
