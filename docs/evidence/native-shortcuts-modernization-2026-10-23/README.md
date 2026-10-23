# Native shortcuts modernization, October 23, 2026

Base: `662ed2f76`. Source: the native shortcuts migration prepared in [#1461](https://github.com/cozyGarage/BookiE/pull/1461), commit `dd19b4e760`. Its older runtime baseline and workflow changes are not included.

The keyboard shortcuts surface now uses `AdwShortcutsDialog`, sections and items, presented with its parent window. Keyboard accelerators remain native shortcut labels; mouse gestures remain translated descriptions. Existing listed shortcuts and window bindings are preserved. The visible-content regression verifies representative labels occur once, more than forty keyboard entries are visible, and Quit/Up/Down accelerators survive. The full regression uses a 400-pixel-wide parent to exercise the adaptive surface.

GTK API features advance from `gnome_47` to `gnome_50` plus `v4_24`; GLib advances to `v2_88`. This implements the deferred API-level step in ADR 0021 without changing its runtime requirements. The calendar date setter uses the current non-optional signature required by the newer API feature.

The app test executable compiled against the new features. The focused visible-content test passed with an 800-pixel parent before the narrow-width strengthening. Full local preflight, strict app Clippy, dependency policy and all 144 widget cases passed, including the 400-pixel parent. Forgejo acceptance is pending. The current baseline gate has independently failed driver byte-budget fixtures and a results-panel focus scenario; those failures are not counted as a pass or attributed to this migration.

This migration pins existing shortcut behavior using the established GTK regression. It does not claim a newly reproduced functional failure in the older shortcuts window. The API deprecation is the reason for replacement. Native Wayland interaction and installed-package acceptance remain unverified.
