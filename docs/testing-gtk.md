# GTK tests

Part of [testing](testing.md), which holds the test tiers, runner and fixtures.

## GTK tests

Run the installed safety suite with:

```bash
./scripts/test-gtk-safety.sh
```

The script builds `tablepro-app`, always starts a private runtime directory, isolated D-Bus session and Xvfb display, and drives the real application through PyAT-SPI. Each scenario gets temporary XDG directories and a fixture SQLite database. A scenario may mark its saved fixture connection as production to test policy prompts; it never opens a user's saved connection or production database. The runner uses a standalone AT-SPI D-Bus daemon and passes the Xvfb display to D-Bus activation, so it does not reuse desktop accessibility or portal processes. GTK tests exercise the X11/GTK portal path; they do not replace installed Wayland package testing.

The runner refuses an empty scenario selection, including an empty shard, or a negative retry count. When selecting one scenario, clear any shard setting that would exclude it.

After its configured retry a failed scenario is recorded and the runner carries on with the rest. Each failure prints a `FAILED:` line and its assertion text, and the run ends with one line that lists every failed scenario and exits non-zero. A scenario that fails only because an earlier one left a shared fixture in a bad state can still fail alongside it, so read the first failure first.

When `TABLEPRO_GTK_ARTIFACT_DIR` is set, every scenario writes a JSON result and application stderr, including successful scenarios. Failures additionally retain the accessibility tree and a screenshot when available. Successful runs therefore have uploadable evidence; a missing artifact still fails CI. Python regressions exercise both result paths without needing a display.

The grid-search keyboard scenario checks focused, visible rows across a 5,000-row result after accepting and dismissing both search dialogs. It complements the 300-column alignment scenario. On X11, these scenarios also capture successful scroll positions when an artifact directory and either `scrot` or ImageMagick `import` are available. Screenshots supplement the focus and bounds assertions; they do not establish native desktop or package acceptance.

Representative end-to-end scenarios in the suite are listed below; the current registry, including scenarios from the GTK workbook, parameter, XML and UX modules, is in [`gtk_safety.py`](../apps/linux/app/tests/gtk_safety.py).

1. Dismissing approval for a fixture connection marked production leaves its SQLite database unchanged.
2. Approving once performs one mutation and prompts again for the next operation.
3. Unavailable audit storage denies the mutation without showing an approval path around the failure.
4. A named `:parameter` in the editor prompts for a value and writes the bound value, not the placeholder text.
5. Ctrl+D saves the editor query as a favorite, and Ctrl+P finds it, opens it, and records the use.
6. A successful saved-connection switch tears down the old workspace and sends writes only to the new database.
7. A failed candidate connection leaves the original editor and database usable.
8. A running read is cancelled and fully settles before the candidate connection is activated; subsequent writes reach only the new database.
9. Current-page CSV export writes exactly the first 100 PK-ordered rows from a 150-row fixture through the real portal chooser.
10. Pending edits gate a connection switch; discarding does not write to either database.
11. A browse tab reopened after switching reads the new connection.
12. Two windows keep queries attached to their own databases.
13. Switching away and back after the persistence debounce preserves workspace tabs.
14. Switching one window preserves another window's pending edits.
15. Current-page JSON export preserves order, Unicode, escaped text, empty text, NULL, and binary values; binary values use `\x`-prefixed hexadecimal, including `\x` for an empty blob.
16. Graceful quit and a new process restore the last connection and selected editor text without executing it; a subsequent explicit Run writes only to that connection. The saved browse tab also reopens.
17. Keyboard column search jumps to the selected column.
18. Committed editor DDL refreshes the sidebar.
19. SQL character warnings leave the editor query unchanged.
20. Current-page XLSX export preserves typed SQLite values, nanosecond times/timestamps, BC/year-10000 dates, wide signed integers, infinity, NULL and formula-like Unicode text. Workbook XML proves native versus text cells and the 100-row page boundary; all source rows remain unchanged.
21. Cancelling the workbook save chooser preserves an existing destination, leaves no temporary export, and leaves all source rows unchanged.
22. Empty text in workbook results produces a visible error with the row/column and CSV/JSON alternatives. No lossy workbook or temporary export is published, and source rows remain unchanged.
23. Repeated named parameters insert exact minimum/maximum signed integers and SQL-like Unicode text into two rows, preserving binding order and treating the payload as data.
24. Cancelling the parameter dialog writes no rows; retrying the same statement uses the replacement values and never executes the cancelled values.
25. XML export round-trips carriage returns, CRLF, LF, tabs, literal entity-looking text and Unicode through an independent XML parser; NULL remains distinct from empty text.
26. XML export of NUL-containing text shows the code point and row/column error, publishes no file, leaves no temporary export and does not change source rows.

The XML scenarios live in `apps/linux/app/tests/gtk_xml.py`. Run `xml_export_preserves_line_endings_and_null_distinctions` or `xml_export_refuses_illegal_text_without_publishing` with `TABLEPRO_GTK_SCENARIO`. Their Python oracle tests deliberately normalize carriage returns and collapse empty text into NULL, requiring both corruptions to fail. Core tests independently check atomic destination preservation for XML-illegal controls and U+FFFE/U+FFFF.

The parameter scenarios live in `apps/linux/app/tests/gtk_parameters.py`; select `repeated_parameters_preserve_wide_ids_and_sql_like_text` or `cancelled_parameters_never_execute_and_retry_uses_new_values` through `TABLEPRO_GTK_SCENARIO` to run one. Registration tests require both in the default suite. Each checks committed SQLite rows independently of the visible UI result.

The workbook scenarios live in `apps/linux/app/tests/gtk_workbook.py` and are registered in the default suite. Their XML oracle has separate negative tests that reject rounded values, wrong types, lost precision, formulas and incorrect page boundaries. SQLite supplies typed Date/Time/DateTime for these UI scenarios; typed TimestampTz UI coverage against a network server remains separate from the core and PostgreSQL contracts. The cancellation UI test stops at the chooser; a core regression also cancels after writing a row and checks atomic destination preservation.

To run one scenario using an already-built candidate (without another Cargo build):

```bash
TABLEPRO_GTK_BINARY=/absolute/path/to/bookie \
TABLEPRO_GTK_SCENARIO=current_page_workbook_preserves_typed_values \
TABLEPRO_GTK_ARTIFACT_DIR=target/gtk-evidence \
bash scripts/test-gtk-safety.sh
```

Use `cancelled_workbook_export_preserves_existing_file` for the cancellation case. Record the binary's commit/checksum; a prebuilt binary is not evidence for later Rust edits. Omit `TABLEPRO_GTK_BINARY` to build the current release profile.

Each scenario creates a temporary profile and fixture connection/database. Its `environment` attribute selects the policy environment to exercise, and `audit_available` controls whether the fixture audit journal is present. These tests do not use existing saved connections or a user's production database.

Memory profiles and second-launch checks retain the exact subprocess launched by the fixture. They verify its PID lifetime and executable file identity rather than scanning process names. Second launch reuses the supplied fixture environment; it never reads another process's environment. Profile rows record the owned PID and Linux process start ticks. An exited or replaced target fails the check instead of selecting another application.

The Open Quickly scenario waits for the filtered result set before invoking its single action; the already-visible favorite is not proof that the debounced row rebuild has completed. It still requires the window to close and usage to be persisted.

Buttons and rows are invoked through named AT-SPI actions; the harness re-queries the row while waiting up to 15 seconds for its action to appear in the accessibility tree. There is no generic Return-key fallback. Keyboard events exercise shortcuts and the export format combo's navigation. The combo has no AT-SPI click/focus action: its scenario tabs until the named control reports focus, opens its list, navigates to the requested format, and verifies its selected label before exporting. Each denial assertion requires the row count to hold for a settle window rather than matching once.

On Arch or Omarchy, install the harness dependencies with:

```bash
sudo pacman -S --needed dbus xorg-server-xvfb at-spi2-core python-atspi
```

The Debian testing CI images use `dbus-daemon`, `gnome-keyring`, `xvfb`, `xauth`, `at-spi2-core`, `python3-pyatspi`, and `scrot`. GitHub pull requests run the required GTK fast checks and widget regressions; the installed GTK safety smoke runs only on a schedule or manual dispatch. The separate daily GTK Safety Soak runs five retry-free attempts and uploads stdout, stderr, accessibility snapshots, and screenshots on failure. The archived [0.2.0 handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md) recorded a release-era criterion of 30 consecutive attempts across at least six runs at one SHA. The maintainer later closed 0.2.0 delivery; that historical criterion does not set future release scope. Current GTK reliability and native Wayland acceptance remain in TEST-31 ([#556](https://github.com/cozyGarage/BookiE/issues/556)) and PKG-1 ([#574](https://github.com/cozyGarage/BookiE/issues/574)) in the [backlog](backlog.md). Service-level tests still cover pure state and policy behavior, but they do not replace these cross-layer tests.

The nightly workflow runs in stages: unit-tier coverage first, then Docker coverage and mutation jobs in parallel, followed by the soak and package jobs. Docker and mutation matrices run at most two jobs at a time. A red job is a failure to classify, not proof of a product bug; use the job log and the [failure-triage guidance](#reading-a-red-nightly) to distinguish code, test, setup and infrastructure causes. Each driver crate is measured with its Docker suite against `baselines/coverage-floors-crates.txt` (`scripts/check-crate-coverage-floors.py`). Mutation results are compared with `baselines/mutants/<package>.txt` by `scripts/check-mutants-baseline.py`: a missed mutant that is not in the baseline fails the run, and baseline lines that a test now catches are listed for deletion. A missing baseline file means no missed mutant is accepted. The soak is three runs of five attempts each per night.

### Reading a red nightly

Sort each red job before touching code. The class decides what the fix and its regression test are.

| Class | How to recognise it | What to do |
| --- | --- | --- |
| Setup failure | The job fails before any test runs: a missing script or path, a wrong binary name, a package missing from an image, a port already in use | Fix the workflow or script, and add a contract test in `scripts/tests/test_ci_workflow.py` or next to the helper. A setup failure hides every later check in that job. |
| Missed mutant | The log lists `NEW missed mutant` | Write a test that asserts the behaviour the mutant changes. Baseline only a mutant that no test can observe, with the reason in the file header. |
| Scenario failure | The soak or an installed GTK shard names a scenario and an assertion | Read the assertion first. The runner carries on after a failure and lists every failed scenario at the end, so start with the first one in the list. |

Every nightly finding that is a product or test gap gets a regression test in the lowest tier that can show it, and an issue when the fix is not immediate. Check a mutation change locally with `cargo mutants -p <crate> --file <file>` and then `python3 scripts/check-mutants-baseline.py <package> <output dir> 3`, which uses the nightly's own judgement. Run a few times: a mutant caught by a timing accident shows up as an occasional miss.

A manual dispatch runs the whole nightly, and the soak and package jobs wait for the mutation jobs. A fix to a nightly-only job is therefore proven by the next night. The contract tests cover its static part.

Workflow prerequisites and runner-specific behavior live in `.forgejo/workflows/` and the scripts they invoke. For a distro-floor failure, use the named scenario and assertion in the job output to distinguish setup, infrastructure and product failures.

SQLite integration regressions also distinguish NULL from zero, false, empty text, and empty blobs in declared columns, and preserve binary values despite declared-type affinity mismatches. Export unit tests overlap writers deterministically and check that pre-existing temporary symlinks cannot redirect writes. Workspace tests preserve active-tab identity when unknown records are removed.

For ordinary UI changes, test the affected flow manually and include before and after screenshots. Add deterministic automation when a regression can be reproduced without timing or desktop-session assumptions.

## Lessons that shape GTK tests

- **Replacing a selected model's contents in one remove-and-add notification makes GTK scan every inserted row.** Deselect, then send the removal, then the insertion. Assert the number of row objects constructed, which is deterministic, not wall-clock time ([TablePro collaboration review](archive/tablepro-collaboration-2026-10-21.md)).
- **A scenario is promoted only after 30 consecutive attempts across at least six runs, and adding a scenario restarts that ledger** ([production audit](archive/production-audit.md)). A diagnostic probe that passes is not a product regression.
