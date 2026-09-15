# TableProEditor

The SQL editor: the text engine, its layout and selection, syntax highlighting, folding, the gutter
and the completion window. It began as two packages from the
[CodeEdit](https://github.com/CodeEditApp) project and TablePro has diverged from both far enough
that they are no longer upstreamable as a whole.

| Target | Vendored from | Licence |
| --- | --- | --- |
| `TableProTextEngine`, `TableProTextEngineObjC` | https://github.com/CodeEditApp/CodeEditTextView at `d7ac3f11f` (2025-07-30) | MIT, `LICENSE-CodeEditTextView.md` |
| `TableProEditorKit` | https://github.com/CodeEditApp/CodeEditSourceEditor at `1fa4d3c3f` (2025-12-31) | MIT, `LICENSE-CodeEditSourceEditor.md` |

Both were vendored in 2026-03 at what was then upstream's tip, and upstream has landed nothing since.

## Why it is one package and not two

Upstream split the engine from the editor because they are two products. Here they are one: 32% of
the commits that touched either touched both, and the strongest co-change pair in the repository is
`TableProEditorKit`'s controller against `TableProTextEngine`'s text view, which the old boundary put
on opposite sides. The targets keep the layering the split was for, and SwiftPM rejects a cycle
between them just as it rejected one between the packages.

## What TablePro changed

Roughly 7,000 lines of source and 7,400 lines of tests, in three groups.

**Correctness and performance in the engine.** Clip-bounded CoreText drawing, per-line widths in the
red-black tree so `maxLineWidth` falls when the widest line is deleted, a typesetting fix where a
line break was used as a length rather than an offset, IME and `NSTextInputClient` range handling,
pasteboard coercion, invisible-character rendering, and range-safety helpers. Most of this is
general and upstream would plausibly want it.

**Product features.** Per-statement run controls in the gutter, and the fold placeholder preview.
These carry no SQL knowledge: `StatementRun` holds an `NSRange` and nothing else, and every SQL
scanner lives in `TablePro/Core/Utilities/SQL/`.

**Replacements.** The completion window was rewritten from `NSTableView` to SwiftUI, and the fold
ribbon from upstream's hover-marker strip to macOS disclosure chevrons. Six upstream files were
deleted outright.

Four subsystems upstream ships were removed because TablePro never used them and two of them were
running anyway: the minimap, jump to definition, the reformatting guide and HTML tag completion
(#2877).

## Taking a change from upstream

Do not expect a rebase to work. 42 of 65 files TablePro touched in the engine, and 41 of 70 in the
editor, collide with what upstream changed in its own last 60 commits. Port a specific fix by reading
it and writing it here, the way any other bug report is handled.

The reverse direction is open: the correctness and performance work is written against upstream's own
shapes and roughly 1,060 lines of it lift out cleanly if anyone wants to send it back.
