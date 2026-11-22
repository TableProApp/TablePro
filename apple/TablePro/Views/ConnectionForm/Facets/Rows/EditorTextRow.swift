//
//  EditorTextRow.swift
//  TablePro
//

import SwiftUI

struct EditorTextRow: View {
    private let title: String
    @Binding private var text: String
    private let prompt: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore

    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, row: EditorRow, store: ConnectionEditorStore) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.row = row
        self.store = store
    }

    var body: some View {
        TextField(text: store.tracking($text, row: row), prompt: Text(verbatim: EditorFieldPrompt.text(prompt, row: row, store: store))) {
            EditorRowLabel(title, row: row, store: store)
        }
        .autocorrectionDisabled()
        .focused($isFocused)
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store, isFocused: $isFocused)
    }
}

struct EditorSecureRow: View {
    private let title: String
    @Binding private var text: String
    private let prompt: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore

    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, row: EditorRow, store: ConnectionEditorStore) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.row = row
        self.store = store
    }

    var body: some View {
        SecureField(text: store.tracking($text, row: row), prompt: Text(verbatim: EditorFieldPrompt.text(prompt, row: row, store: store))) {
            EditorRowLabel(title, row: row, store: store)
        }
        .focused($isFocused)
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store, isFocused: $isFocused)
    }
}

// A borderless field with nothing in it is invisible, so every field shows a prompt: the facet's example when it has
// one, else whether the field must be filled in. A required field that is empty carries an issue on its row.
@MainActor
enum EditorFieldPrompt {
    static func text(_ example: String?, row: EditorRow, store: ConnectionEditorStore) -> String {
        if let example, !example.isEmpty { return example }
        return store.issues(for: row).contains { $0.severity == .error }
            ? String(localized: "Required")
            : String(localized: "Optional")
    }
}
