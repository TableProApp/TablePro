# AUD-2 MySQL approval reruns

The MySQL unparseable-routine denial workflow passed three consecutive local
runs against the per-user BookiE release binary built from `fork/linux`
`97e5f55bddacdfef427c51f162917fedcace3a9f`. The current Linux tip `2b7258c1`
contains the same approval implementation and GTK harness files; PR #453 only
updated documentation.

Each run started a fresh MySQL 8.0 Docker fixture and isolated D-Bus, Xvfb and
AT-SPI environment. The scenario found the approval dialog, denied the
unparseable routine, verified no routine was created, approved the next
request, and verified it was created. Logs are retained as `attempt-1.log`
through `attempt-3.log`.

These passes show the earlier empty accessibility snapshot was not reproduced
in this local environment. They do not identify the cause of gtk-server runs
55 and 56, prove the flake fixed, or establish package-manager/native Wayland
acceptance.
