# 0041: A result window can keep its line breaks

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

[0003](0003-result-windows-for-native-grids.md) packs a window's text and cuts it "with control characters made spaces so a cell is one line". The Windows grid now wraps its cells when the user asks (#4329), and a line break in a value has to break the line there. A space cannot be turned back into a break in C#, so the core has to hand the breaks over.

Two things were wrong with the one-line text as well:

- `push_line` replaced bytes below 0x20 and 0x7f only. NEL (U+0085), the line separator (U+2028) and the paragraph separator (U+2029) are two and three bytes in UTF-8, so they passed through, and a cell that was meant to be one line reached DirectWrite with a mandatory break in it.
- Each grid had its own idea of a line break: the macOS grid seven forms, the core the C0 controls, the Windows grid's typed text the C0 and C1 controls.

## Decision

This amends the one-line cell of 0003. The window keeps two fetches. `tablepro_cursor_fetch` stays as it was, one line per cell. `tablepro_cursor_fetch_lines` is the same window with each line break kept as one `\n`. Both read one set of break forms: LF, CR LF, CR, VT, FF, NEL, U+2028 and U+2029.

- **One line** (`fetch`): each break form is one space, as is every other C0 and C1 control and DEL. CR LF stays two spaces, as it was.
- **Kept breaks** (`fetch_lines`): each break form is one `\n`, CR LF one `\n` for the pair. Every other control is one space, as in the one-line text, so a tab still cannot shift a column.
- `max_chars` counts the value's own characters in both, before any break is folded. A CR LF counts two, so a kept window can hold fewer characters than the cap, never more, and the 4 GiB bound on a window is the same sum.
- Hex for binary and the type name of an unreadable value are the same in both.
- The window still carries display text only. The full value, with the break forms as stored, comes from the calls 0003 names for the detail pane, the editor and copy.

## Rationale

- A second export leaves `tablepro_cursor_fetch`'s signature, its callers and its tests alone. A flag on it would change the ABI every caller links.
- Every form becomes `\n` in the core, so no grid depends on which forms its text engine breaks at. Pango, measured, does not break at VT, FF or NEL; Core Text does; DirectWrite was not measured. One tested function decides instead.
- The same classifier flattens and keeps, so wrap off and wrap on cannot disagree about what a line break is.

## Consequences

- The one-line text of a value that holds NEL, U+2028, U+2029 or a C1 control changes: each is now one space, one byte where it was two or three. A test pins the new text (`every_line_break_form_is_one_space_on_one_line`); `text_is_cut_at_a_character_and_kept_on_one_line` and the cursor's window tests hold as they were, since their values hold LF and tab only.
- A kept `\n` may stand for CR LF or another form, as a space may stand for a tab. A grid that copies from display text has to read such a cell whole; the Windows grid marks it lossy ([Windows 0023](../../../windows/docs/decisions/0023-wrapped-cells-and-uneven-rows.md)).
- A trailing break is kept in the window. A grid that does not want an empty last line drops it.
- `window_abi.rs` gained an export, so `windows/src/TablePro.Interop/Generated/WindowMethods.g.cs` was generated again.
- The Linux app reads its rows through the Rust API and has its own display text, so it does not call either fetch.

## Alternatives considered

- **A flag on `tablepro_cursor_fetch`.** One export, but an ABI change for every caller and its tests.
- **Keep the stored break forms and let each grid fold them.** Three folds again, and the grid's text engine would see forms it may not break at.
- **Undo the spaces in C#.** A space that was a break cannot be told from one that was typed.
