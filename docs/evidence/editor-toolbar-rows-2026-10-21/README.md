# Editor toolbar rows, October 21

Source base: `5eed1a729`; runtime code matches the 0.2.0 tag. Owner: [#1279](https://github.com/cozyGarage/BookiE/issues/1279).

## Reproduction and cause

A headless PostgreSQL run repeatedly reported that the editor toolbar required more width than its allocation. The application can allocate about 630 logical pixels to the editor in a 640-pixel window, but the editor itself requested a 640-pixel minimum. Its single action row also exceeded the available width when optional query controls were shown. Hiding the folding buttons at the existing breakpoint did not bound that row in every state.

The warning flood can fill an unread stderr pipe in a long-running accessibility harness. The saturated PostgreSQL probe now writes stderr directly to a file. This separates the harness stall from application execution and is already part of the owning issue.

## Change

Query status, cancellation, session and Run controls occupy one row. Folding, warnings, pinning, Explain and split controls occupy a second row. The timeout retry remains a separate transient bar. The editor minimum is 600 logical pixels, within the existing application window minimum. Existing labels, tooltips, messages and keyboard shortcuts are preserved. No database, policy, cancellation or value contract changes.

A wrapping-grid prototype was discarded after a short headless screen exposed excessive vertical allocation. The final change uses the existing GTK box container and bounded rows.

## Regression and validation

The regression fails against the original 640-pixel editor minimum. It exposes running, warning and retry controls together, then checks their actual allocations at requested widths 600, 630 and 910, with ordinary and 20-pixel toolbar text. Run, Cancel and retry remain inside the editor, both rows fit the allocated width and the source editor keeps positive height. A 640×480 Xvfb environment may clamp the largest request; a separate 1280×1024 run verifies the wider allocation. The initial resize test sampled child allocations before the next layout completed. Waiting for the following frame preserves the bounds assertions and passes the 1280×1024 run, including the 910-pixel allocation.

Local preflight, all 104 registered GTK tests and application all-target Clippy passed on the final two-row implementation. The updated full GTK suite also passed all 104 tests after the 910-pixel case and frame synchronization correction. Documentation and exact-head Forgejo acceptance remain pending at this checkpoint.

These are headless layout and behavior checks. A sustained optimized before/after CPU comparison and native visual acceptance are not established by the GTK regression.

## Current Linux refresh, October 22

Merged Linux through `4f61f2f98`, including the accepted PostgreSQL terminal-page metadata fix and nonblocking GTK stderr capture. Full preflight and all 104 registered GTK tests passed again on merge head `1a66246d87a5100ac10cb1045fdd2c7a872c22ce`. The toolbar Rust source and isolated-test registry are unchanged from the previously tested toolbar head `250fb184046b7092f27fba7691842099afc3338b`. Exact-head Forgejo acceptance remains pending.
