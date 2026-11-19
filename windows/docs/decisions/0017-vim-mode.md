# 0017: Vim mode in the SQL editor

- **Status**: Accepted
- **Date**: 2026-11-19

## Context

The macOS editor has a Vim mode behind its Key bindings setting (`apple/TablePro/Core/Vim`), with suites that pin each motion, operator, register, count, visual mode and ex command (`apple/TableProTests/Core/Vim`). The Windows editor is our own control ([0002](0002-sql-editor-control.md)), which already wraps lines and folds them. Windows has no Cmd key: Ctrl is the shortcut key, Alt opens the menus, and Win+V keeps a clipboard history.

## Decision

### Engine

- `TablePro.Editor.Model/Vim` is a port of the macOS engine to C#, so its tests run on any machine (`tests/TablePro.Editor.Model.Tests/Vim`, one suite per macOS suite plus the Windows additions). A key is one text element; control keys come as their control characters.
- It works on the editor model through `VimTextBuffer`: a character is a grapheme cluster (`StringInfo`), as macOS's composed character sequence is; `f` and `t` compare characters canonically, and `~`, `gU` and `gu` use Unicode's full case mapping, so `ß` becomes `SS`, as Swift's does.
- Each key the engine takes is one undo step, and an insert is one step from the key that started it to Escape (`UndoHistory.Coalesce`), as Vim undoes it; an arrow or a click inside the insert starts a new step. A macro replayed by `@` is one step, `u` inside it undoes the macro's own changes (`UndoHistory.Checkpoint`), and it types again what Insert mode typed.
- Marks keep their line and column, as Vim's do (`:help mark-motions`), through every change to the text, typed, pasted or undone, not only the engine's own: whole lines added or removed at a line start move the marks on and below them, a join carries a mark with its text, an edit on a mark's line keeps its column, and removing a named mark's line removes the mark, while `''`, the last insert and the last Visual selection go to where the lines were. A line changed in place, as `>>` or `gUU` changes it, keeps its marks.
- A command that ends drops the count and register typed for it, and Escape drops every prefix of one, an operator included. After an operator only a motion, a text object, a search or the operator doubled continues the command; a motion that finds nothing ends it. Operators follow `:help exclusive`, `cw` changes to the word's end, a linewise change leaves one empty line, `>` and `<` shift whole lines, and `ip` and `ap` take whole lines. A count before `p` pastes the chosen register each time, a counted `P` keeps each copy whole, and `a` and `p` on an empty line stay on it. In Visual mode `"x` picks the register, `p` keeps the text it replaces and `P` leaves the registers alone, and a text object moves Visual's anchor and cursor. Enter, `+` and `-` go to a line's first character, and a word motion steps over a symbol with a variation selector.
- Registers and macros are the app's, shared by every editor (`VimRegisters.Shared`), as Vim keeps them across buffers. Each yank and delete also reaches the clipboard, as on macOS, but kept out of clipboard history and other devices (`ClipboardContentOptions`), since Vim writes on every `x`.

### Folds and wrapped lines

- `j`, `k`, Visual `j` and `k`, and Ctrl+D, U, F and B count a closed fold as one line and leave it closed. `gj` and `gk` move by rows on screen. `H`, `M` and `L` read the rows on screen.
- `dd`, `yy`, `cc`, `>>`, `<<`, `g~~`, `gUU`, `guu`, `dj`, `dk`, `dG`, `dgg` and `V` take a closed fold whole; `p` and `P` linewise and `o` put the new lines below or above the whole fold. A search, a mark or `%` that lands inside a fold opens it, as every caret jump does.
- `zo`, `zc`, `za`, `zR` and `zM` fold as the editor's Fold, Unfold, Fold All and Unfold All do; `zz`, `zt` and `zb` scroll, and Ctrl+E and Ctrl+Y scroll by rows, moving the cursor only when it leaves the view. macOS has no folds and takes these keys without doing anything.

### Keys

- Characters reach the engine first, from `CharacterReceived` and from TSF: outside Insert mode an input method's text is Vim's keys. Other keys go through `VimKeyRouter` before the editor's own commands, and the app's accelerators come after both.
- Normal and Visual take the Ctrl chords Vim defines (A, B, D, E, F, H, N, P, R, U, X, Y); Insert and Replace take Ctrl+D, T, U and W. Every other chord, Ctrl+Shift and Alt are the editor's and the app's, so Ctrl+C, Ctrl+V, Ctrl+Z, Ctrl+S and Ctrl+Enter keep their Windows meaning. Ctrl+[ is Escape.
- Arrows, Home, End, Page Up, Page Down, Delete, Backspace and Enter are their Vim keys outside Insert mode (`h`, `l`, `k`, `j`, `0`, `$`, Ctrl+B, Ctrl+F, `x`, `h` and Enter). Escape with nothing to cancel in Normal mode is the editor's, so it still closes find and drops extra carets.
- The Edit menu sends its keys to the editor directly ([0004](0004-app-shell.md)), so Select All, Copy and Paste from the menu do what they say in any mode.

### Screen

- Outside Insert and Replace the caret is a block over the character, the caret color at 40 percent, as macOS draws it; in Visual mode it sits on Vim's cursor, which can be the selection's start. A click, a paste or a menu command that moves the selection ends Visual mode.
- The query tab's bar shows a badge with the mode, or the command line while one is typed, colored by mode as macOS's is, then the keys of a command still being typed and `recording @q`. The badge's name says "Vim mode" and the mode for Narrator.
- `:w` runs the query, `:q` closes the tab through its usual prompts, and `:tabnext`, `:tabprevious`, `:tabNext`, `gt` and `gT` select tabs, as macOS has them (`VimCommandLine`).
- Settings has Vim mode in its Editor section, off by default.

## Rationale

- A port keeps one behavior across the apps and brings the macOS suites with it. The Linux app takes GtkSourceView's own Vim, which Windows has no equivalent of.
- The engine stays in the model, not the core: it edits the editor's own carets, folds and undo history on every key, which an FFI round trip per key would only slow.

## Consequences

- Ctrl+A, B, F and P mean Vim's commands in Normal mode, so Select All, Find, Show objects and Filter objects are reached from the Edit and View menus then, and Ctrl+D pages instead of adding the next match. Ctrl+W and Ctrl+T in Insert mode delete a word and indent, not close and open a tab.
- `.` repeats `x` and `dw`-style operator motions only, as on macOS.
- Visual block mode, `:s`, `:{line}` and text typed by `.` are not built, as on macOS.
- A macro keeps the keys Vim sees, typed text included, but not the keys Insert mode leaves to the editor (arrows, Home, End, Ctrl shortcuts), as on macOS. Replaying those needs the editor's commands, paste and undo among them, to run inside the macro's undo step and in order, which is a design of its own.
