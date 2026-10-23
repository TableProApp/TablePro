# Read-only label selection allocation experiment

Related work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315). Source: `9f749bb7c34d91458a9272a75127cde90bfee13e`, the [#1519](https://github.com/cozyGarage/BookiE/pull/1519) keyboard-routing candidate. This is diagnostic evidence, not acceptance of a product behavior change.

GTK's [selectable label property](https://docs.gtk.org/gtk4/property.Label.selectable.html) enables mouse text selection. The supported [GTK 4.24.1 implementation](https://github.com/GNOME/gtk/blob/4.24.1/gtk/gtklabel.c) initializes selection state, drag and click gestures, motion and focus controllers, and a content provider when that support is requested. BookiE enables it for every realized read-only cell.

The experiment changed that one property to false in an unshipped executable. Both executables used the same development profile, dependencies and source base. Three fresh processes per variant ran in alternating order with the same isolated Xvfb/Cairo fixture, 100 generated SQLite rows and 257 columns, zero retries, first-value observation and a two-second settle. Process identity and binary hashes were checked. The production source was restored immediately after building the diagnostic executable.

| Median loaded RSS | MiB |
| --- | ---: |
| Selectable labels | 623.8 |
| Plain labels | 544.1 |
| Difference | 79.7 |

[Raw measurements](measurements.json), [binary identities](binaries.json) and the [diagnostic-only patch](diagnostic-only.patch) preserve the cases. Reproduction uses the same [probe](https://github.com/cozyGarage/BookiE/blob/9f749bb7c34d91458a9272a75127cde90bfee13e/docs/evidence/grid-keyboard-menu-routing-2026-10-23/probe.py) and [isolated runner adaptation](https://github.com/cozyGarage/BookiE/blob/9f749bb7c34d91458a9272a75127cde90bfee13e/docs/evidence/grid-keyboard-menu-routing-2026-10-23/runner.patch) as the keyboard-routing measurement, with variant names selectable and plain. The wait bound was 45 seconds. No shipping-profile, PostgreSQL, leak or general latency conclusion is established.

The plain-label variant removes mouse text selection and changes native text-selection accessibility. It is not an accepted optimization and must not be shipped as a fix. The result supports investigating deferred selection setup or another cell presentation that preserves interaction. Any implementation must retain mouse drag selection, exact keyboard copy, assistive text operations, focused-cell menus, recycled row identity and lifecycle cleanup. Substantial wide-grid memory remains even without this selection machinery.

## Next bounded experiment

The candidate still installs a right-click `GestureClick` and captures menu state for each cell in `attach_cell_gesture`. The existing grid-level empty-area handler already performs pointer picking. Measure sharing the cell handler at grid scope before replacing native label selection. This is a source-derived hypothesis; no memory saving is established for it.

Use the candidate from #1519 as the baseline. Preserve the selection property, existing menu actions and weak ownership. Resolve the cell from the pointer target and its ancestors, rather than keyboard focus, then use the existing cell metadata and menu preparation. Keep native editor menus available during an active edit. A click outside a cell must retain the existing empty-area behavior.

Acceptance requires a regression that fails with per-cell controllers, pointer selection of a different cell from the focused one, a rebound row with updated identity, editable and read-only cells, native active-edit handling, empty-area behavior and grid teardown. Installed tests must activate an actual menu action and check its value. Re-run the alternating fresh-process measurement with matching binaries, then the full GTK and Forgejo acceptance. Do not infer a saving from controller counts alone.
