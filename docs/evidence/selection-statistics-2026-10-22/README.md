# Selection statistics resource investigation

Source baseline: `2277e7b73921fdec1db270ffc6b5fb43336d637c`.
Tracker: [#1353](https://github.com/cozyGarage/BookiE/issues/1353).

## Verified mechanism

The browse selection callback computes its tooltip synchronously. It collects
selected rows using `with_cells(|cells| cells.to_vec())`. `with_cells` already
materializes a cloned row. The second copy remains in a full selected-value
matrix until numeric statistics finish. Text, binary and JSON payloads are
copied even though they cannot contribute numeric statistics.

The existing `RowObject::with_cell_value` accessor borrows both locally owned
and shared result cells. It provides the required lifetime boundary without
changing the stored values or driver contracts.

## Scope

Change only selection statistics and its caller. Preserve exact decimal sums,
null skipping, finite float checks, overflow refusal, mixed-type refusal and
missing-cell refusal. Preserve selection counts and row inspector behavior.
Tests must pin these outcomes. A wide nonnumeric payload test pins existing
numeric behavior before changing access.

## Matched heap measurement

[Measurement metadata](measurements.json) records binary, source and trace hashes.
Both debug test binaries use the same baseline, toolchain and GTK fixture. The
baseline has only the added fixture; the candidate includes the borrowed-cell
change. Each run creates 64 rows with an integer and 512 KiB text, then computes
the selection tooltip eight times. Row and selection preservation are asserted.

| Metric | Baseline | Candidate |
| --- | ---: | ---: |
| Peak heap, MB | 100.56 | 66.47 |
| Peak RSS including profiler, MB | 226.63 | 207.43 |
| Instrumented total time, seconds | 0.66 | 1.50 |

The heap reduction is 34.09 MB. Baseline backtraces include payload cloning in
`selection_tooltip` and `with_cells`. This is one pair of debug widget-test
runs, not a whole-application benchmark. Startup and shared-host noise make
CPU or latency improvement unproven; the candidate total time was worse.
Outstanding allocations at process exit were 32.52 MB in both runs. They are
not evidence that selection payloads leak.

Raw traces, saved binaries, reports and the reproduction script are retained
under `~/bookie-test/selection-statistics/`. Runs use private XDG directories,
D-Bus and Xvfb, with the X11/Cairo backend and accessibility disabled.

## Validation status

Six baseline behavior tests passed before and after changing access. Eight
candidate unit tests now pass, including unfetched cells and decimal overflow.
The matching wide-selection GTK fixture passes on both binaries and pins
existing observable behavior. It is a profiling fixture, not an allocation
limit assertion. The initial branch passed full preflight, 721 application
unit tests, application Clippy and 105 isolated GTK widget tests. After
merging Linux `ad9bb1447163c848919616773ab0971c5a2d2135`, refreshed preflight
passed all 2,054 tests (64 skipped), and all 106 isolated GTK widget tests
passed. Documentation links, issue ledger and ignored-test inventory pass.
Forgejo acceptance for the refreshed head remains pending. Native desktop
responsiveness has not been checked.
