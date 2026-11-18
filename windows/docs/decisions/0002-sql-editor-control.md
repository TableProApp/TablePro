# 0002: TablePro's own SQL editor control

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

- A SwapChainPanel holds a composition swap chain (flip sequential, three buffers, at most two frames waiting). A frame starts only when the swap chain can take it, through its frame latency object, so Present never blocks the UI thread. Direct3D 11 runs on the GPU, or WARP when there is none or software rendering is asked for. Direct2D draws on it, DirectWrite lays out each visible line.
- Every editor on a UI thread draws on one Direct3D and Direct2D device, as the grid's rows do (0003), and the first editor to find it lost replaces it for the rest. Each editor has its own device context and swap chain. TabView unloads a tab's content on every switch, so a hidden editor gives back its swap chain (`SetSwapChain(null)`) and keeps its layouts and brushes; showing it again makes one swap chain.
- Line layouts are cached by text and colors, so lines that shift after an edit keep theirs; only the edited line is laid out again. A line over 4,096 characters is laid out in a slice around the visible columns.
- A frame is drawn on the UI thread when something changed, and many changes before it give one frame. It holds the gutter, current line band, find matches, selections, text and IME marks. The carets are a composition visual of their own over the swap chain, one sprite per visible caret, as WinUI's TextBox keeps its caret in an element of its own (`TextBoxView.cpp`, `EnsureCaretElement`). SwapChainPanel draws its swap chain first (`SwapChainPanel.cpp`, `GetChildrenInRenderOrder`), so the panel's child visual lies above it. A frame places the sprites at the positions it laid out, snapped to pixels; a blink, focus or the window's activation only shows or hides the visual, with no frame. On `windows-2025` (run 43277097648) focus and a 5 second blink of 10 toggles presented 11 frames when the frame held the caret, and 0 with the visual. WinUI raises LostFocus on the focused editor when another window takes the activation, and GotFocus when it comes back (run 43614838421), so focus leaving clears the composition and draws only when one was shown. The caret blinks at the system rate, with the system caret width, and stops after the system caret timeout (`SPI_GETCARETTIMEOUT`, 5 seconds when the call fails) with no input, shown, as a Win32 edit control's does. In an inactive window (`InputActivationListener`) it is hidden and nothing blinks, as Win32's About Carets asks.
- Why a SwapChainPanel and not Composition drawing surfaces: one surface, presented when something changed, and a frame time measured from input to present; the same model as Windows Terminal. Surfaces per line would add their own management for scrolling that this cost does not need.
- Colors: theme resources for the chrome. In high contrast the system colors, selected text in the highlight text color, and no syntax colors.
- DPI: the buffer is in pixels and the panel's composition scale shrinks it back. Ctrl+wheel, Ctrl+= and Ctrl+- zoom.

### Input

- TSF through `ITfContextOwner`, ported from Windows Terminal's `src/tsf` (MIT): TSF owns a transitory store that holds only the text being composed. The editor draws it at the caret with the IME's underlines and moves finished text into the document as typing. The IME never reads the 5 MB document, and composition never reaches the undo history.
- `CoreTextEditContext` was not used. In a WinUI 3 desktop app `CoreTextServicesManager.GetForCurrentView()` and `CreateEditContext()` do succeed (gate run 41448673455). Its context is not transitory, so the IME would read the document, the reason Windows Terminal left it. Whether it receives input in a desktop app was not tested.
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
| Ctrl+Shift+[, Ctrl+Shift+] | Fold the innermost region at the caret, unfold the one on its line |

- Typing closes brackets and quotes and steps over a closer already there; Enter keeps indentation and opens a bracket pair onto its own lines; Backspace in indentation goes back one tab stop.
- Mouse: click, Shift+click, double-click word, triple-click line, drag to select with auto-scroll, drag and drop of text (a move inside the editor is one undo step), and a context menu.

### Rows: word wrap and folding

- `VisualRows` in the model maps document lines to the rows on screen. With no wrap and no fold a row is a line and nothing is stored. Drawing, hit testing, carets, scrolling and the UIA geometry all read rows.
- Word wrap breaks a line by columns, as a monospaced font lays it out (`LineWrap`): a wide East Asian character or an emoji takes two, a combining mark none, a tab runs to the next stop of its row. A row breaks after its last space, else at the edge, and spaces hang past the edge, as Notepad and VS Code wrap. Each row is its own DirectWrite layout, so the drawing breaks where the model does. An edit lays out only its own lines again; a new width lays out every line.
- A caret at a row's first offset draws at the start of that row. Up and Down move by rows and keep their column; Home and End stay on the row, as a wrapping Windows text box has them, and the first row keeps smart Home.
- A fold keeps its first line on screen with a chip after its text and hides the lines after it (`FoldSet`). Folding never touches the document, so it makes no undo step. A caret sent into a fold, by find, undo or Go to Error, opens it; Left and Right step over a fold. An edit on the hidden lines, or one that splits or joins the first line, opens it.
- Chevrons in a gutter column show while the pointer is over the gutter, and stay on a folded line, as the macOS editor and VS Code reveal them. A click on a chevron or a chip folds or opens. The menu has Fold, Unfold, Fold All and Unfold All; Fold All folds top-level regions only, as the macOS editor's does.

### Statements, fold regions and bracket pairs

- `ISqlStructure` is what the lexer knows past colors: its statement split and which of its kinds carry structure. `CoreSqlLexer` splits through the core's `tablepro_script_statements`, the split the drivers and Run Statement read, from UTF-16 with no copy into a UniFFI string.
- `DocumentStructure` reads the statements and the fold regions of one version of the text: statements over more than one line, multi-line block comments, brackets (to the line before the closer, as VS Code folds them) and `BEGIN` or `CASE` to `END`. A text up to 64 KB is read before the frame that needs it; a longer one off the UI thread once typing pauses for 200 ms, mapped through each edit in between. Over 2,000,000 characters there are none, the limit the macOS editor stops at.
- The band behind the statement the caret is in is the host's to turn on, as the macOS editor's is. It is the statement Run Statement sends: the one the primary caret is in, or the last one before it, and it steps aside for a selection.
- The bracket beside the caret, before it first as the macOS editor reads it, and its pair get a box, as VS Code and Visual Studio mark them on Windows. Only a bracket the lexer gives as punctuation or an operator pairs, so one inside a string, a comment or a quoted name never does. A text the lexer gives no tokens for, such as a MongoDB query, pairs plain characters.

### Color schemes

- The editor half of each built-in macOS theme is a scheme (`windows/scripts/editor-schemes.py` writes `ColorSchemes.Themes.cs` from `apple/TablePro/Resources/Themes`). The host picks one for light and one for dark; none keeps the Windows colors. Names the user wrote, punctuation and quoted names draw as text, as the macOS editor colors them. High contrast draws the system colors whatever the scheme.

### Accessibility

- A FrameworkElementAutomationPeer of type Edit with TextPattern and TextPattern2: document range, selections, visible ranges, caret range, range from point, bounding rectangles in screen pixels.
- Character, word and line units move by the model's own rules. Units it does not have fall back to the next larger one: format to word, paragraph to line, page to document.
- Bounding rectangles come one per row on screen, so a wrapped line gives several and a folded one none, and the visible ranges split where a fold hides lines.
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
- Seams for the later slices: the lexer is an `ISyntaxLexer`; the model's commands and `SqlEditor.HandleKey` are public; `FramePresented` reports every frame. Completion, hover, diagnostics, formatting and Vim are not built.
- A new width lays out every line again for word wrap, which on a 5 MB script costs a pass over its text per column the width gains or loses.
- The fold chevrons have no UIA element of their own; the keys and the menu reach every fold.

## Alternatives considered

- **RichEditBox.** Failed its gate (Context).
- **A fork of an editor** (Scintilla through WinUIEdit, AvalonEdit). Ruled out by the maintainer. Scintilla's design (a gap buffer with lazy line starts, styling up to a frontier) and AvalonEdit's (a rope, a line tree, a document separate from its view) were studied; the per-line facts and the frontier come from them.
- **A gap buffer.** Moving the gap across a 5 MB document is O(n); the rope's edits are O(log n).
- **A piece table.** O(log n) as well, but the rope keeps each line's characters in few contiguous leaves, which DirectWrite and the lexer read directly.
- **Composition drawing surfaces or Win2D.** Win2D is a dependency over the same Direct2D; per-line composition surfaces add work that one swap chain does not need.
- **A full `ITextStoreACP2`.** Gives reconversion, at the price of TSF's lock protocol over a 5 MB store. Possible later behind the same control.

## Gate, 2026-11-02

The same 5 MB script as the RichEditBox gate (5,243,031 characters, 48,702 lines), drawn with WARP on GitHub's `windows-2025` (x64) and `windows-11-arm` (Arm64) runners, keys sent with `SendInput`. The harness is on the local branch `spike/windows-editor`.

| Bar | x64 | Arm64 |
|---|---|---|
| Typing at the end, input to present, p95 (max) | 10.8 ms (25.6) | 6.9 ms (13.9) |
| Typing in the middle, p95 (max) | 5.1 ms (6.4) | 3.9 ms (7.2) |
| Scrolling 3 lines a step, scroll to present p95 (max); drawing p95 | 20.4 ms (21.0); 5.3 ms | 19.7 ms (20.9); 4.0 ms |
| Scrolling a page a step, same | 22.7 ms (49.3); 6.9 ms | 6.6 ms (21.5); 5.8 ms |
| 50 keys, then one Ctrl+Z | one undo step, text restored exactly | same |
| Coloring while scrolling and jumping | no undo or redo step | same |
| Telex, keys ` tieengs vieetj ` | stays raw, as a stock TextBox does on Windows Server 2025 (lane `wingates2`) | composes `tiếng việt` at the caret |
| Pinyin, keys `nihao` then 1 | composes `ni'hao` at the caret, candidate window 3 px under the caret line, commits `你好` | composes and commits; candidates under the composition in the screenshot |
| UIA | text, caret line and caret rectangle read back right, also while composing | same |

Run 41472137359. A Native AOT build of the harness ran typing, scrolling and UIA within the bars on both.
