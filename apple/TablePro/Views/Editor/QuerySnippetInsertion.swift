//
//  QuerySnippetInsertion.swift
//  TablePro
//

import AppKit
import TableProAutocomplete
import TableProEditorKit
import TableProTextEngine

/// Puts a saved query picked from the query bar's Snippets menu into the editor, the way completion
/// does when it accepts a favorite's keyword (`QueryCompletionAdapter.completionWindowApplyCompletion`):
/// tab stops become fields Tab walks through, and the `;;` marker (`SQLSnippetMarker`) is where the
/// caret ends up.
@MainActor
internal enum QuerySnippetInsertion {
    /// A query with neither tab stops nor the marker goes in as written, with the caret after it.
    nonisolated internal static func snippet(for sql: String) -> EditorSnippet {
        SQLSnippet.parse(sql).map { EditorSnippet($0) } ?? EditorSnippet(text: sql, fields: [])
    }

    /// At the caret, or over the selection as typing would. The editor takes focus back from the
    /// menu, so the first field can be typed into at once.
    internal static func insert(_ sql: String, into controller: TextViewController) {
        controller.insertSnippet(snippet(for: sql), replacing: controller.textView.selectedRange())
        controller.view.window?.makeFirstResponder(controller.textView)
    }
}
