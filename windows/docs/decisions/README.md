# Architecture Decision Records

Decisions only the Windows app makes. A decision every platform shares is in `core/docs/decisions/`.

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md).

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-sql-editor-control.md) | TablePro's own SQL editor control | Accepted | A rope with its own undo in a plain .NET model, drawn with Direct2D and DirectWrite into a SwapChainPanel, TSF as Windows Terminal does it, a UIA text provider, and the core's lexer for colors. |
