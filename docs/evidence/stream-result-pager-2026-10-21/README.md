# Bounded SQL result pager, October 21

Source base: `1c95b9ec1`. Owner: [#1273](https://github.com/cozyGarage/BookiE/issues/1273). The selected presentation is an explicit pager over retained pages, with a notice when earlier rows have left the bounded cache.

## Reproduced defects and checks

The existing isolated presentation test failed after asserting that page tabs are hidden. It also failed when the expected second-page range was corrected from `Rows 5001-5001` to `Rows 3-3` for a two-row page followed by one row. Initial construction and live appending now calculate row positions from total received rows and retained page lengths. Page sequence numbers remain identities, not row offsets.

The label defect does not establish the cause of an earlier PostgreSQL row-ID observation. The current PostgreSQL cursor normally requests 5,000 rows per fetch; row identifiers need not equal result positions, especially without an explicit order.

Previous/Next controls navigate retained pages and terminal status. Their sensitivity reflects the available range. Live eviction refreshes the controls. The received-row summary names the retained row range when earlier rows are no longer available. No automatic SQL rerun, cursor repositioning or additional row retention is introduced. Export continues to use its existing separately guarded execution.

The pager GTK regression covers navigation bounds, status, eviction and releasing the notebook while its controls remain alive. The existing loading/terminal presentation case verifies hidden tabs and short-page labels. A pure regression covers row positions after eviction. Existing ownership tests remain registered.

## Verification

Arch Linux, private X11/Xvfb, Cairo. All 93 isolated GTK cases passed. Full preflight, the pure row-range regression, app all-target Clippy, doc links, issue ledger, isolated-test inventory and translation checks passed.

The full-app screenshot probe could not start its private AT-SPI registry (`org.a11y.atspi.Registry` activation failed before application discovery). No application crash was established. Dark/light screenshots at 5,000 and 150,000 received rows and native Wayland interaction remain unverified. The issue remains open until this visual acceptance is recorded. This change makes no CPU-speed or process-memory claim; [#1272](https://github.com/cozyGarage/BookiE/issues/1272) remains separate.
