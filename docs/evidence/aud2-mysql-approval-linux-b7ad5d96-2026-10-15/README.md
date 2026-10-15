# AUD-2 MySQL approval workflow at `b7ad5d96`

Date: 2026-10-15

Source: `b7ad5d96a0af3de87df14d00830c92aee9fb732f` (`docs(b4): add AUD-9 masking matrix result`). The product binary was built from this Linux source.

Environment: Rust/Cargo 1.98.1, Docker Engine 29.7.2, MySQL `8.0`, private D-Bus, Xvfb, AT-SPI and PyAT-SPI.

Command:

```bash
python3 scripts/run-test-layer.py gtk-mysql-approval
```

Result: passed; exit code 0; 20.716 seconds. The layer report recorded `status: passed` and the `mysql_unparseable_routine_dialog_denial_preserves_database` scenario passed, including the approval dialog and database-preserving denial. The log printed `A connection to the bus can't be made` after the scenario pass; the layer report still recorded exit code 0.

The approval unit checks also passed on this source:

```bash
cargo test --locked -p tablepro-app --lib services::gtk_approval::tests -- --test-threads=1
```

Result: 11 passed, 0 failed, 859 filtered out. Source inspection confirms a 120-second request deadline, a GLib timer that denies and closes a still-visible dialog, and a SQL preview capped at 16,384 characters. The unit suite covers preview truncation and expiration while queued; it does not exercise expiration while the dialog is visible or its audit outcome.

This is source-build Xvfb evidence. It does not establish installed Arch/Hyprland or native Wayland acceptance, timeout while a dialog is visible, or the corresponding terminal audit event. The frozen-candidate acceptance on [#598](https://github.com/cozyGarage/BookiE/issues/598) remains open for those items.
