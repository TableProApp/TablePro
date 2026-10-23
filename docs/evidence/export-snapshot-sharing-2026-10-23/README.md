# Export snapshot sharing investigation

Source: Linux `e6f73eca9`, October 23, 2026.

The loaded-result export path owns a `QueryResult` in the dialog. Clicking Export clones that result into `SaveRequest`; accepting the file chooser clones it again into `JobSource::Loaded`. Both clones copy the row vectors and owned values on the GTK thread. Paged export uses a separate source and must retain its cancellation and finish behavior.

The proposed correction shares the immutable dialog snapshot with the file request and worker through `Arc<QueryResult>`. It does not alter export formats, exact values, truncation state or the snapshot initially selected by the caller.

A regression named `loaded_export_keeps_the_existing_row_allocation` checks that the file job retains the original row allocation and its values and truncation state. Its initial run failed on the row-allocation identity assertion before the fix. The corrected implementation wraps the selected snapshot once and shares it through both later stages. All 15 non-display export tests pass after the fix. Full preflight passes. The full GTK tier stops at the unrelated, pre-existing truncation-visibility assertion fixed by PR #1495. All three registered export display tests were then run individually in isolated Xvfb sessions and passed: full-export refusal, row-scope presentation, and disabled unqualified snapshot export. No measured process-memory reduction or Forgejo acceptance is claimed yet.
