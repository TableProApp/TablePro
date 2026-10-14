# B4 current Linux tip local recheck

Date: 2026-10-13
Source: `472a50be84aa7c981abcb316950e21eba2158c24` (`fork/linux`)

These local runs recheck B4 scenarios against the current Linux tip. They do not replace a Forgejo gate, frozen-candidate acceptance, installed Arch/Hyprland acceptance, or the nightly soak.

## Results

| Layer | Command or scenario | Result |
| --- | --- | --- |
| MySQL approval UI | `bash scripts/test-gtk-mysql-approval.sh` | Passed: `mysql_unparseable_routine_dialog_denial_preserves_database`; the approval dialog appeared, denial preserved database state |
| PostgreSQL lost acknowledgement | `cargo test --locked -p tablepro-driver-postgres --test integration disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1` | Passed: 1 test; committed write was not replayed after reconnect |
| PostgreSQL release | `bash scripts/test-postgres-release.sh` | Passed: 59 release tests, 1 system OpenSSH test, 3 mTLS tests, and 7 GTK trust/audit scenarios |

The PostgreSQL release scenarios included the read-scoped plan refusal, `EXPLAIN ANALYZE` denial with the table intact, SSH host-key refusal and setup-failure audit, tunnel-loss retirement and reconnect, multi-hop trust, second-hop decline, changed-key refusal, and saved mTLS behavior.

## Environment and limits

The GTK scenarios ran with the script's isolated D-Bus, Xvfb and AT-SPI setup. The release script's first two attempts stopped before product assertions because a long temporary-directory path made the OpenSSH control socket exceed the Unix socket path limit. The successful run used a short-lived runtime-directory symlink to a temporary directory; both were removed after the run.

These are source-build local results on the current tip. They are not evidence for the older frozen candidate `bbdc39a430ede9382bc5dfa7164e51a065e2bd88`, and they do not establish Forgejo, installed-package, native Wayland, or power-loss acceptance.
