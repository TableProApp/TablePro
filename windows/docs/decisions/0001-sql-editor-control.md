# 0001: TablePro's own SQL editor control

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

- WinUI 3 has one rich text control, RichEditBox. Its gate failed on a 5 MB script (lane `wingates`, 2026-11-02):
  - typing in the middle took 1.27 to 1.33 s for 15 of 50 keys, with coloring off;
  - recoloring the visible range cost about 160 ms;
  - every format change entered its undo stack, and TOM's `Undo(tomSuspend)` is not reachable from WinUI 3.
- The maintainer ruled out forks of third-party editors.
- The editor has to take input methods (Vietnamese Telex, Chinese Pinyin, Japanese, Korean), be read by Narrator, follow the theme and high contrast, and keep the keys and behaviors of the macOS editor (`apple/Packages/TableProEditor`).

## Decision

`TablePro.Editor` is a WinUI 3 control of our own: a rope with its own undo history in a plain .NET model, drawn with Direct2D and DirectWrite into a SwapChainPanel, input methods through TSF as Windows Terminal takes them, a UIA text provider, and colors from the core's SQL lexer.

## Design

### Model (`src/TablePro.Editor.Model`, net10.0, no WinUI)

- The text is a rope: a height-balanced tree of leaves of at most 2,048 characters. Each node caches its length and its count of `\n`, so an insert, a delete, offset to line and line to offset each walk one path: O(log n). Typing into a leaf with room edits it in place.
- Line breaks are stored as `\n`. `LineEnding` puts the file's own break back on export (save, clipboard). TSF and UIA offsets count this normalized text.
- Undo lives in the model (`UndoHistory`). One operation is one step whatever the number of carets. Typing, Backspace and Delete runs join the step before them as the macOS editor groups them: an insert joins while it continues the last one, has no line break and does not start a word after one. Moving a caret ends the run. Paste, cut and line commands are steps of their own.
- Multiple carets are a sorted list of selections; overlapping ones merge, and one is primary. Edits apply bottom up, so earlier offsets hold.
- Nothing about coloring or drawing enters the model's document, so coloring never makes an undo step.

### Coloring

- The core lexes (`core/crates/core/src/sql_syntax/highlight.rs`, exported as `tablepro_syntax_tokens`). It takes and returns UTF-16 offsets.
- The lexer only reads from a clean start, so the highlighter keeps one fact per line: does it start outside every token, or inside one that began above (a block comment, a string)?
- Drawing a range lexes from the nearest clean line above it to the last visible line: only the visible range is styled.
- An edit moves the frontier of known facts back to the edited line. Lexing forward stops at the first line after the edit that is clean again as before, since a clean start on unchanged text reads the same way. Facts per line sit in a gap list, as Scintilla keeps its per-line data.

### Drawing

- A SwapChainPanel holds a composition swap chain (flip sequential, two buffers). Direct3D 11 runs on the GPU, or WARP when there is none or software rendering is asked for. Direct2D draws on it, DirectWrite lays out each visible line.
- Line layouts are cached by text and colors, so lines that shift after an edit keep theirs; only the edited line is laid out again. A line over 4,096 characters is laid out in a slice around the visible columns.
- A frame is drawn on the UI thread when something changed, and many changes before it give one frame. It holds the gutter, current line band, find matches, selections, text, IME marks and carets. The caret blinks at the system rate, with the system caret width.
- Why a SwapChainPanel and not Composition drawing surfaces: one surface, presented when something changed, and a frame time measured from input to present; the same model as Windows Terminal. Surfaces per line would add their own management for scrolling that this cost does not need.
- Colors: theme resources for the chrome. In high contrast the system colors, selected text in the highlight text color, and no syntax colors.
- DPI: the buffer is in pixels and the panel's composition scale shrinks it back. Ctrl+wheel, Ctrl+= and Ctrl+- zoom.

### Input

- TSF through `ITfContextOwner`, ported from Windows Terminal's `src/tsf` (MIT): TSF owns a transitory store that holds only the text being composed. The editor draws it at the caret with the IME's underlines and moves finished text into the document as typing. The IME never reads the 5 MB document, and composition never reaches the undo history.
- `CoreTextEditContext` was not used: `CoreTextServicesManager.GetForCurrentView` needs a CoreWindow, which a WinUI 3 desktop app does not have, and its context is not transitory, the reason Terminal left it.
- Keys follow Windows text boxes, and VS Code on Windows where a text box has none:

| Keys | Command |
|---|---|
| Arrows, Ctrl+Left/Right, Home (smart), End, Ctrl+Home/End, PageUp/Down, with Shift to extend | Move carets |
| Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z | Undo, redo |
| Ctrl+X/C/V, Shift+Delete, Ctrl+Insert, Shift+Insert | Clipboard; with nothing selected, Copy and Cut take the line |
| Ctrl+Backspace, Ctrl+Delete | Delete a word |
| Ctrl+D | Select the word, then add the next match as a caret |
| Ctrl+Alt+Up/Down | Add a caret above or below |
| Alt+click, Alt+drag | Add a caret, select a column |
| Escape | Close find, or keep only the primary caret |
| Alt+Up/Down, Shift+Alt+Up/Down, Ctrl+Shift+K | Move, copy, delete lines |
| Ctrl+/, Tab, Shift+Tab, Ctrl+], Ctrl+[ | Line comment, indent, outdent |
| Ctrl+F, F3, Shift+F3 | Find, next, previous |

- Typing closes brackets and quotes and steps over a closer already there; Enter keeps indentation and opens a bracket pair onto its own lines; Backspace in indentation goes back one tab stop.
- Mouse: click, Shift+click, double-click word, triple-click line, drag to select with auto-scroll, drag and drop of text (a move inside the editor is one undo step), and a context menu.

### Accessibility

- A FrameworkElementAutomationPeer of type Edit with TextPattern and TextPattern2: document range, selections, visible ranges, caret range, range from point, bounding rectangles in screen pixels.
- Character, word and line units move by the model's own rules. Units it does not have fall back to the next larger one: format to word, paragraph to line, page to document.
- Text changes and selection changes raise their UIA events.

### Interop

- TerraFX.Interop.Windows (MIT) declares Direct3D, DXGI, Direct2D, DirectWrite and TSF. The four TSF interfaces the editor implements are declared for the COM source generator, so the control stays Native AOT compatible.

## Rationale

- Each part of the failed gate is a part we now own: layout per visible line instead of a whole-document layout, coloring outside the document instead of formatting in it, and an undo history coloring cannot reach.
- The model has no WinUI, so its tests run on any machine with `dotnet test`.

## Consequences

- Text input, hit testing and accessibility are ours to keep right; RichEditBox's own behaviors no longer come for free.
- A transitory TSF context gives up reconversion and IME features that read the text around the caret.
- The composition is drawn at the primary caret only, and committed text goes to every caret.
- Seams for the later slices: the lexer is an `ISyntaxLexer`; the model's commands and `SqlEditor.HandleKey` are public; `FramePresented` reports every frame. Completion, hover, diagnostics, formatting, Vim and folding are not built.
- Not yet: word wrap, bracket matching, the current-statement band, regex find, replace.

## Alternatives considered

- **RichEditBox.** Failed its gate (Context).
- **A fork of an editor** (Scintilla through WinUIEdit, AvalonEdit). Ruled out by the maintainer. Scintilla's design (a gap buffer with lazy line starts, styling up to a frontier) and AvalonEdit's (a rope, a line tree, a document separate from its view) were studied; the per-line facts and the frontier come from them.
- **A gap buffer.** Moving the gap across a 5 MB document is O(n); the rope's edits are O(log n).
- **A piece table.** O(log n) as well, but the rope keeps each line's characters in few contiguous leaves, which DirectWrite and the lexer read directly.
- **Composition drawing surfaces or Win2D.** Win2D is a dependency over the same Direct2D; per-line composition surfaces add work that one swap chain does not need.
- **A full `ITextStoreACP2`.** Gives reconversion, at the price of TSF's lock protocol over a 5 MB store. Possible later behind the same control.
