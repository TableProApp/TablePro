# Current Linux-tip PostgreSQL release checks

Date: 2026-10-13

Source: `1ff2ff9cbbac10d6105554d7b964f87c562efd6f` (`fork/linux`)

Script: `scripts/test-postgres-release.sh`

Command: `bash scripts/test-postgres-release.sh`

## Results

| Layer | Result |
| --- | --- |
| System OpenSSH trust fixture | Passed: 1 test |
| mTLS fixture | Passed: 3 tests |
| PostgreSQL release tests | Passed: 59 tests |
| GTK trust and audit scenarios | Passed: 7 scenarios |

The PostgreSQL release tests include read-scoped plan denial, `EXPLAIN ANALYZE` denial with the table intact, transaction rollback, host-key and TLS refusal, transport reconnect, and saved TLS routes. GTK scenarios passed for saved mTLS, unknown host-key decline, SSH setup failure audit, tunnel-loss retirement and reconnect, multi-hop trust, second-hop decline, and changed-key refusal.

The run used a Linux host with Docker and rustc 1.98.1. GTK ran using the script's isolated D-Bus, Xvfb and AT-SPI setup. After all seven scenarios passed, shutdown printed `A connection to the bus can't be made`; the script exited with status 0.

This is local source-build evidence at the stated SHA. It does not establish frozen-candidate, Forgejo, installed-package, native Wayland, bundle-import, or nightly-soak acceptance. The tested SHA is newer than the maintainer-designated frozen candidate `bbdc39a430ede9382bc5dfa7164e51a065e2bd88`.
