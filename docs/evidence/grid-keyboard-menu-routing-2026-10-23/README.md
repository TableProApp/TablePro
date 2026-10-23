# Shared grid keyboard menu handling

Candidate source base: Linux `a950891e6`. Related work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315).

The measured many-column construction path creates keyboard controllers, shortcuts and callback actions for each realized cell. The candidate retains per-cell right-click gestures and immutable cell metadata, while one managed keyboard controller per grid resolves the current focused cell. It handles native cell wrappers and nested editor focus, refuses focus outside its grid, and leaves an in-progress text editor to its native menu.

The existing registered GTK regression now uses actual column-factory cells. Against unchanged baseline production code, its final allocation assertion failed because application keyboard callbacks remained on the cell. The candidate passes the focused-cell checks, updated reference/export state, editable cell and checkbox targeting, and refusal during in-progress editing. Native GTK label shortcuts remain intact and are excluded from the application callback count.

An installed Xvfb scenario sends Menu on the first result row and Shift+F10 after moving to the second. It navigates to View Value using the existing keyboard helper and verifies the opened text each time. The candidate passed with zero retries in 4.042 seconds. This validates real event routing rather than only direct callback activation. Temporary structural diagnostics used during investigation were removed before the matched artifact build. The clean measured candidate passed this scenario again in 4.181 seconds, the existing pointer menu/accessibility scenario in 2.095 seconds and the full-value viewer scenario in 3.002 seconds, all with zero retries. Full preflight, strict application Clippy, all 153 isolated GTK tests and all 788 non-display app tests passed. Forgejo acceptance remains required.

GTK documents [managed shortcut scope](https://docs.gtk.org/gtk4/method.ShortcutController.set_scope.html) for handling shortcuts outside the controller widget's own focus. Direct callback tests alone did not establish this: the initial local-scope candidate failed installed event delivery. The focused native cell also contains an internal widget wrapper, so direct-first-child assumptions were replaced with a search within the focused cell.

Shared controller counts are a structural allocation invariant. The matched resource measurement below is separate from full GTK/Forgejo acceptance.

## Matched wide-result process measurements

Three fresh baseline processes and three fresh candidate processes ran in alternating order with the same dependencies, unoptimized development profile, toolkit, Xvfb/Cairo display, isolated fixture and generated SQLite query. Each result had 100 rows and 257 columns. Measurements waited for the first value and then settled for two seconds. No retries were used. [Raw results](measurements.json), [binary identities](binaries.json), [probe](probe.py), and [isolated runner adaptation](runner.patch) preserve the experiment.

| Median | Baseline | Candidate |
| --- | ---: | ---: |
| Initial RSS | 196.5 MiB | 196.6 MiB |
| Loaded RSS | 637.4 MiB | 622.9 MiB |
| RSS growth | 441.3 MiB | 426.5 MiB |

Median loaded RSS fell 14.53 MiB, or 2.28%, for this workload. The candidate still used about 623 MiB, so the dominant wide-grid construction cost remains unresolved. Three observations per variant do not establish a general performance guarantee. This is a synthetic installed-application result, not a shipping-profile or PostgreSQL benchmark and not evidence of leak freedom. Recorded first-value timings include accessibility inspection and are not a latency acceptance claim.

To reproduce, copy the standard GTK safety runner, apply runner.patch to that copy, and set TABLEPRO_PROFILE_REPO to the checkout, TABLEPRO_PROFILE_RUNNER to the adapted runner and TABLEPRO_PROFILE_SCRIPT to probe.py. Set TABLEPRO_GTK_BINARY to an immutable installed-path executable, TABLEPRO_GTK_SCENARIO to profile_wide_grid_controller_allocations, TABLEPRO_MENU_VARIANT to the case name, and TABLEPRO_MENU_MEASUREMENT_OUT to its result file. The recorded run used TABLEPRO_GTK_WAIT_SECONDS=45 and TABLEPRO_GTK_SCENARIO_RETRIES=0. The runner retains the existing private D-Bus, Xvfb, keyring and cleanup setup.

Native Wayland, shipping-profile memory, native text-selection menu accessibility and other database engines were not measured by this experiment.
