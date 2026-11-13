# 0028: A shared result masks its columns before it leaves the machine, with the macOS app's output

- **Status**: Accepted
- **Date**: 2026-11-14

## Context

A share link ([0027](0027-share-links.md)) sends a result's rows to tablepro-cloud for anyone with the link to read. On 2026-11-13 the maintainer decided that the share sheet hides sensitive values before they leave the machine: each shared column can be kept, masked in a style or removed, and columns that look sensitive start masked. The macOS app masks values in five styles (Full, Last 4 Characters, Email, Stable Hash, NULL); a link from any app must read the same. On 2026-11-14 the maintainer limited masking in the Linux and Windows apps to sharing: no per-connection rules, and no masking of the grid, exports, MCP or the assistant.

## Decision

- **Styles.** `tablepro_core::masking::mask_value` gives the macOS app's output byte for byte, from the text `export::value_text` writes at the column's declared precision: four U+2022 bullets; Last 4 Characters and Email by extended grapheme cluster, Email on the last `@`; Stable Hash as the first 6 bytes of HMAC-SHA256 under a key drawn once per process and never stored; NULL stays NULL under every style; bytes hash raw and otherwise show bullets.
- **The plan.** `masking::SharePlan` takes the sheet's Keep, Mask(style) or Remove for each visible column. A removed column is never read, a masked one is masked as it is sent, and the snapshot names each masked column's style (`SnapshotColumn::masked`, the share link's `columns[].masked`). `create_share`, `ResultSet::share_preview` and `ResultSet::share_summary` all go through it, so the sheet shows and counts what is sent.
- **The body budget.** As on macOS, `build_snapshot` weighs each masked cell as the macOS app does and stops before the row that would take the body past 4,500,000 bytes, keeping the row count so the server marks the share cut. A cell over 256 KiB, or a first row past the budget, refuses the share (`SnapshotTooLarge`, worded as `account.snapshot_too_large`). `snapshot_row_count` gives the preview, the summary and the detectors that same prefix.
- **Detectors.** `masking::detect` suggests a style per column from its name (whole words), from the values of a text-like column over the rows a share sends (card with Luhn, IBAN with mod-97, JWT, API keys, email, phone, IP), and finds personal data in the SQL's single-quoted literals, comments skipped, to suggest Hide SQL. The lists, thresholds and edge cases are PLAN-MASKING 8.3 and 8.3.1; `detect/fixtures.rs` pins them and the macOS app mirrors the same table. `secret_scan` follows the same definition: no lookaround or possessive runs, CR, LF and CRLF line breaks, the name splitting the detectors use.

## Consequences

- A suggestion is only a starting point: the user may keep a detected column, and nothing masks a column the user keeps.
- The macOS app keeps its per-connection masking rules, which also apply to its Share Result; the Linux and Windows apps have none.
- A pattern or threshold added to the detectors changes all three apps only once the macOS lane mirrors the fixtures.

## Alternatives considered

- **Per-connection rules in the core, applied to the grid, exports, MCP and the assistant on Linux and Windows.** Built first, then dropped by the maintainer's 2026-11-14 decision to keep masking to sharing.
- **The app masks each value before sending it.** Three engines would drift on grapheme counting and hashing, and a share link would read differently by the app that made it.
- **A stored hash key.** A hash could then be looked up across launches and apps; the macOS key is per launch on purpose.
