# Evidence preserved before retiring B4 worktrees

Preserved 2026-10-11 from completed local branches. These are historical results
at their recorded source revisions, not acceptance of the current release tip.
Original manifests and limitations are retained; unavailable raw logs remain
unavailable. Old branch edits to the ledger were not imported.

| Original branch | Preserved record |
|---|---|
| `docs/b4-hosted-linux-tip-20261009` | [Hosted tip](../b4-hosted-linux-tip-2026-10-09/manifest.json) |
| `docs/b4-release-evidence-100fb6fa` | [Extracted package binary](../b4-packaged-binary-acceptance-2026-10-10/manifest.json), explicitly not package-installed acceptance |
| `docs/b4-current-tip-20261010` | [Rollback run](../b4-rollback-linux-tip-d4950ba2-2026-10-10/manifest.json) |
| `b4/mysql-advisory-lock-rollback-20261009` | [Approval run](../mysql-approval-current-linux-2026-10-09/manifest.json) |
| `b4/s6-s7-joined-verdict` | [PostgreSQL release run](../b4-current-postgres-release-b7d80b2-2026-10-10/manifest.json) |

The three old candidate worktrees point to the same external build cache through
`linux/target` symlinks. Removing the symlinks and checkouts preserves that cache.
