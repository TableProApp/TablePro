# Keyboard cell menu state, October 23, 2026

Scope: a focused follow-up to [#1031](https://github.com/cozyGarage/BookiE/issues/1031), not completion of its broader grid guard matrix. Base: `662ed2f76`.

Pointer-opened cell menus refreshed reference and loaded-row export action states, while keyboard-opened menus refreshed only editing actions. Because the popovers and actions are shared, keyboard availability could remain stale after changing cells or filters.

The existing registered Menu/Shift+F10 widget test now activates the actual shortcut callback. It failed before the repair because an eligible non-null reference cell kept a disabled reference action. After the repair it verifies reference eligibility for non-null and null cells, and loaded-row export availability as a local filter is applied and cleared.

Both entry points now call the same preparation function. Reference eligibility reads only the selected cell instead of cloning the complete row. Cell identity, selection, editing and exact values are preserved. Per-cell options are shared between the two callbacks; no new controllers were added. No measured memory reduction is claimed for this focused correctness repair.

The focused regression passed after the fix. Before/after local logs are `target/quality/keyboard-menu-before.log` and `target/quality/keyboard-menu-after.log`. Full preflight, all 144 registered isolated widgets, and strict app Clippy passed on the recorded base. After integrating Linux `cb1afab95`, full preflight, strict app Clippy and all 147 registered isolated widgets passed again. Current-head logs are `target/quality/keyboard-menu-current-preflight.log`, `target/quality/keyboard-menu-current-clippy.log` and `target/quality/keyboard-menu-current-widgets.log`. Forgejo acceptance remains pending.

Validation on integrated Linux `7bacfe3ea` passed full preflight, strict app Clippy and all 152 widgets. Tested head: `75107baf6a4a92c8516e73903bfdda3b7afb49ef`. Logs are `target/quality/keyboard-menu-latest-preflight.log`, `target/quality/keyboard-menu-latest-clippy.log` and `target/quality/keyboard-menu-latest-widgets.log`. A later Linux result-limit notice is integrated before publication; this does not claim an exact-head Forgejo pass.
