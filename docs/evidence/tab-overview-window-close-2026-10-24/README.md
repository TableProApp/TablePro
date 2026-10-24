# Tab overview close control

## Reproduction

On 2026-10-24, the installed `bookie 0.2.0-1` build showed an extra X at the far right of the `2 Tabs` overview header. Clicking it exited BookiE. The per-tab X controls on the tab cards and the normal titlebar close control were also visible, so the extra control was easy to mistake for a view-close action.

The installed binary was `/usr/bin/bookie`, SHA-256 `b406fd8055670abc230cfead154eb27ff39dbff7f46ca8a4b0f67a6c6c50b971`. The reproduction used Hyprland on native Wayland, GTK 4.24.1, and libadwaita 1.10.0. The SQLite fixture at `/tmp/bookie-native-ui-20261024.sqlite` remained 8192 bytes after the app exited.

## Cause and change

`AdwTabOverview` shows its end title buttons by default. In BookiE this added window-level controls beside the tab cards. The workspace overview now disables those end title buttons while preserving each tab card's own close control and the normal window titlebar controls.

## Verification

The isolated GTK regression test first failed with the default setting and passed after the fix. The full GTK widget tier passed with 164 tests, and `scripts/preflight.sh` passed with 2,078 unit tests and 2,090 sandbox tests. The candidate binary used for the native check had SHA-256 `81d74a9363ba819af1b42f58eaaf65f01f59fffdd67773421142f48649eabc05`.

In the candidate, the extra overview-header X was absent. Both tab-card X controls remained. Pressing Escape dismissed the overview and left the application window open with both tabs. The SQLite fixture remained 8192 bytes. Screenshots show the pre-fix overview, the fixed overview, and the open window after dismissing the overview.

The native candidate was built before the latest four commits on `linux` were merged into this branch; those commits did not change the overview implementation. The GTK regression and full preflight are rerun on the merged branch before publishing this change.

## Screenshots

- [Before fix](tab-overview-before-fix.png)
- [After fix](tab-overview-after-fix.png)
- [Overview dismissed, window still open](overview-dismissed-window-open.png)
