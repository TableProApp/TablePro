# Actual editor scrolling resource observation

Source: application `d980faa29`, Linux `0053bf339` plus the workspace-restoration fix. Debug/dev build, GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0. The executable hash is in results.json. The application ran under isolated Xvfb, D-Bus, XDG directories and a synthetic SQLite fixture; the locked desktop was not used.

The existing profile_large_result_in_the_grid harness scenario requested 100,000 six-column rows, then moved the accessible vertical scrollbar through the middle, end and top. It observed row 100,000 at the end and rows 1 through 6 after returning to the top. The scenario passed without retries. This exercises actual editor result presentation rather than the standalone factory probe.

| Phase | RSS, MiB |
| --- | --- |
| Before query | 204.1 |
| After load | 266.6 |
| Middle | 268.3 |
| End | 268.3 |
| Return to top | 268.2 |

The application status reported done in 903 ms; the harness observed the first result after 1.76 seconds. These are different measurements. Forty configured scroll steps and settling waits contribute to the 18.532-second scenario duration. Local validation ran concurrently, so timing is descriptive, not performance acceptance. Reported process high-water samples vary slightly and are retained as raw observations, not treated as precise peak allocation evidence.

Reproduce using the recorded binary and harness: set TABLEPRO_GTK_BINARY to that executable, TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid, TABLEPRO_GTK_SCENARIO_RETRIES=0, TABLEPRO_PROFILE_ROWS=100000, TABLEPRO_PROFILE_SCROLL_STEPS=40 and TABLEPRO_PROFILE_OUT to an owned output file, then run bash scripts/test-gtk-safety.sh from the recorded source.

This single six-column SQLite observation does not repeat the original two-million-row PostgreSQL streaming workload, prove cancel/close reclamation, establish leak freedom or quantify wide-column costs. The data does show limited additional resident growth during the measured scroll traversal. [#1272](https://github.com/cozyGarage/BookiE/issues/1272) and [#1315](https://github.com/cozyGarage/BookiE/issues/1315) remain open.
