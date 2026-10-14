# AUD-2 MySQL approval workflow

Date: 2026-10-13

Source: `6c777a0dc2a6a053d59dc759ab3e226906edaa7d` (`fork/linux`)

Command: `CARGO_TARGET_DIR=[user-home]/Projects/bookie-b4-postgres-snapshot-pages/target bash scripts/test-gtk-mysql-approval.sh`

Fixture: Docker image `mysql:8.0`, image digest `sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b`

Runtime: Omarchy Linux host, Docker Engine 29.7.2, rustc 1.98.1. The script builds the release app and runs the selected GTK scenario under its isolated D-Bus, Xvfb and AT-SPI setup.

## Result

Exit code 0. The `mysql_unparseable_routine_dialog_denial_preserves_database` scenario passed. It found the approval dialog and its SQL preview for an unparseable `CREATE PROCEDURE`; denial left the procedure absent. It then approved a second procedure and verified that it existed. The test also confirmed no unexpected database rows were created.

After the pass line, shutdown printed `A connection to the bus can't be made`. The script still exited with status 0.

This is source-build Xvfb evidence on the current Linux tip. It does not establish frozen-candidate, installed Arch/Hyprland, native Wayland, Forgejo or nightly acceptance. The installed AUD-2 timeout path and its audit result remain unverified here.

## Approval helper unit checks

Command: `CARGO_TARGET_DIR=[user-home]/Projects/bookie-b4-postgres-snapshot-pages/target cargo test --locked -p tablepro-app --lib services::gtk_approval::tests -- --test-threads=1`

Result: 11 passed; 0 failed; 785 filtered out; exit code 0. This covers preview truncation, denial defaults, window selection, cancellation while queued, and the 120-second queued-dialog deadline. It does not exercise timeout while a visible dialog is open or verify the resulting audit event on an installed build.
