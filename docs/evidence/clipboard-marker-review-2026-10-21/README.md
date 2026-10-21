# Clipboard marker review, October 21

Scope: [PR #1206](https://github.com/cozyGarage/BookiE/pull/1206), head `83084d6690f72f657887794dcca2751f6a5a909c`, implementing [#1184](https://github.com/cozyGarage/BookiE/issues/1184). Comparison: BookiE `1dff6fd97`. This is a parser-level reproduction, not an installed GTK or database test.

The patch applies `undo_copy_markers` to every cell returned by the plain-text clipboard parser. The paste route reads text with `read_text_future`; it supplies no format or producer identity to distinguish application-generated markers from literal external text.

| Plain-text clipboard input | Current linux parser | PR parser |
|---|---|---|
| Literal backslash followed by N (`\N`) | Same two-character text | Empty string |
| Literal `"'=1+1"`, including both double quotes | Same text | `=1+1` |

Reproduction extracted the exact pure parser functions from each revision into a standalone Rust test executable. Two assertions compared the returned cells with the input text. `rustc --edition=2024 --test` compiled both executables. Both assertions passed against current linux and failed against the PR head with the results above. No parser logic was rewritten in the harness. The transient executables and source extraction remain outside tracked product code.

The existing value parser maps blank input on nullable columns to SQL NULL. The parser result therefore establishes a data-change risk for literal marker text; no stored-value reproduction is claimed here. Ordinary external text must not be decoded solely because its characters resemble an internal marker. A producer-specific clipboard format or another provenance mechanism should distinguish internal value interchange while preserving spreadsheet-safe plain text. Validate NULL separately from literal marker text, empty text and default intent. Formula-looking text, tabs, newlines and quotes require round-trip cases through the actual copy and paste routes.

No product fix is included in this review. PR #1206 owns the implementation; its acceptance must address these cases before merge. This review does not establish any fault in its independent workspace-restoration changes.
