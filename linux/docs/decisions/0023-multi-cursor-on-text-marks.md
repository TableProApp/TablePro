# 0023: Multiple cursors on text marks, in the app

- **Status**: Accepted
- **Date**: 2026-10-24

## Context

The SQL editor is a GtkSourceView 5.18 view. GtkTextView has one cursor, its `insert` and `selection_bound` marks, and neither GTK 4.22 nor GtkSourceView 5.18 has an API for more ([#3648](https://github.com/TableProApp/TablePro/issues/3648)). The sourceview5 bindings expose nothing either, so the feature is work in the app or upstream.

## Decision

The editor's view is a `GtkSourceView` subclass in the app that keeps each extra cursor as a pair of `GtkTextMark`s and runs every edit and move once per cursor.

## Rationale

- Marks follow every edit the buffer makes, so the cursors move with the text. A selection's start and end keep text typed at their edge outside, as GTK's own selection does.
- GTK's own commands do the work at each cursor: the subclass overrides GtkTextView's class methods (`move_cursor`, `backspace`, `delete_from_cursor`, `insert_at_cursor`, the clipboard ones), points GTK's cursor at each mark pair in turn and chains up. Word moves, grapheme deletes and GtkSourceView's auto-indent stay GTK's.
- Text an input method commits arrives on its own, asynchronously with some input methods. It is recorded while the user action runs and repeated at the other cursors from `end-user-action`, which GTK emits before it closes the undo group, so one undo takes back the edit at every cursor.
- GtkSourceView's key handler edits with Return, Tab and BackSpace itself (auto-indent, indenting lines, its Ctrl+BackSpace), with no class method to override. Once the input method has passed on such a key, the editor sends it to the view once per cursor.
- The extra cursors and selections are drawn in `snapshot_layer`, the documented place for drawing over and under the text, in the colours GtkSourceView and libadwaita give GTK's own.

## Consequences

- The editor depends on GTK's class methods and `end-user-action` order (`gtktextbuffer.c`: the signal before `gtk_text_history_end_user_action`). A GTK release that changes either shows in the editor's tests.
- The extra cursors do not blink and are not in the accessibility tree; the editor announces how many cursors there are instead.
- GTK's undo history puts back its own cursor only, so an undo or a redo returns to one cursor, where the edit was. Each edit at several cursors is its own undo step, since GTK joins only single edits that follow each other, and typing over selections longer than one character is two, as GTK makes it for its own cursor (`gtk_text_view_commit_text`).
- Vim mode edits the buffer itself, so extra cursors are off while it is on. Overwrite keeps one cursor too, and the completion list opens only with one: both act on the text around GTK's cursor, which the other cursors' text need not match.
- Moving lines and words and joining lines act on GTK's cursor alone, after returning to one cursor, since two cursors on one line would move it twice.
- The editor takes GtkSourceView's Shift+Alt+Up and Down (scroll by one line) for adding a cursor above and below: GNOME's window manager takes Ctrl+Alt+Up and Down.

## Alternatives considered

- **Upstream in GtkSourceView.** The right home in the long run, but the API would reach users only with a GNOME release after the platform floor (ADR 0015) moves to it. The app's subclass can give way to an upstream API then.
- **Text tags for the extra selections.** A tag travels with copied rich text inside the app and colours pasted text; drawing in `snapshot_layer` leaves the buffer alone.
- **Sending every key press to each cursor.** An input method that answers asynchronously commits once, at whichever cursor is GTK's when it answers, and shortcuts such as undo or paste would run once per cursor.
