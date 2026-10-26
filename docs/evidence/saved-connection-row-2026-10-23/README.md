# Saved connection row layout, October 23

This record captures the saved-connection row from commit `30f72c168` in light and dark themes at 320 px and 560 px widths. The synthetic connection uses a long Unicode name and endpoint. The GTK widget test applies 20 px text, measures the row in a mapped Xvfb window, and checks that the title receives at least 120 px and the favorite, actions-menu and open controls remain allocated.

The images show the row widget only and do not establish transparency under Omarchy. The welcome list and saved-connection popover use the same row factory. A source-built `ci` binary from `30f72c168` passed focused GTK/AT-SPI scenarios for editing a saved connection, Group/Tags, removal from the welcome list, and keyboard traversal of the row controls. The keyboard test checks the accessible names and click actions, tabs through Favorite, Actions and Open in order, then activates Open with Return. The test environment was Xvfb, not native Wayland.

The GTK allocation test passed on the recorded commit. It emitted GTK warnings that an internal `GtkBox` reported a natural height smaller than its minimum height at both widths. This did not fail the assertions, but remains a native desktop review item.

## Checks

- `bash scripts/preflight.sh`: passed. This included 2,070 unit tests, 2,082 sandbox tests and the Redis cancellation test. Debian package validation was skipped because `dpkg-deb` is unavailable.
- `bash scripts/test-gtk-widgets.sh`: 144 tests passed, including the saved-connection row allocation test.
- Focused screenshot test: passed at commit `30f72c168` using Xvfb, 20 px CSS text and synthetic data.
- `scripts/test-gtk-safety.sh` with four selected saved-connection scenarios: edit, Group/Tags, welcome-list removal, and keyboard focus order plus Return activation; all passed against the source-built binary from `30f72c168`.
- `cargo clippy --locked -p tablepro-app --all-targets -- -D warnings`: passed before the final commit; the final commit changed no Rust after that check.

Native Wayland visual review and screen-reader narration remain unverified.

The Xvfb run emitted routine DRI3, portal and bus warnings in addition to the `GtkBox` measurement warning. These are test-environment messages, not proof of desktop acceptance.

## Follow-up, October 26

On Linux source head `d5274f0b571ae11821d12666b6fcad0a6856c331`, the focused allocation test passed its text-width and action-allocation assertions. It still emitted `GtkBox` warnings at constrained widths 316 px and 179 px: minimum height 52 px, natural height 50 px. This run used GTK 4.24.1 and libadwaita 1.10.0 under Xvfb.

A bare `AdwActionRow` control with similar long Unicode title/subtitle text and the same 20 px CSS did not emit the measurement warning. The warning therefore appears with BookiE's composed row under the narrow allocation, but this comparison does not identify the specific child or establish visible clipping. Native Wayland visual review and screen-reader narration remain outstanding; the issue stays open.

## Screenshots

| Theme | 320 px | 560 px |
|---|---|---|
| Light | [light-narrow.png](light-narrow.png) | [light-normal.png](light-normal.png) |
| Dark | [dark-narrow.png](dark-narrow.png) | [dark-normal.png](dark-normal.png) |

SHA-256:

- `dark-narrow.png`: `128fd53421559fed457b41e89eb43fc365e2641aa7ae0beb3d317818519bd207`
- `dark-normal.png`: `9bd410be56e879351e910c8ce1a697e528057ae39d0f5cca3a5f3e4eb44d3f0d`
- `light-narrow.png`: `be1be23f28775d4b8742f7a8ff15a0cec5e248430e0d1a1658fca4738a528e9f`
- `light-normal.png`: `3b7c4bd25ef414b4da89eefda421d391619e90ba89bf7fe9d664904172601358`
