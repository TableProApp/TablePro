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

    @State private var isEdited = false
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, row: EditorRow, store: ConnectionEditorStore) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.row = row
        self.store = store
    }

    var body: some View {
        TextField(text: $text, prompt: prompt.map { Text(verbatim: $0) }) {
            EditorRowLabel(title, row: row, store: store, isEdited: isEdited)
        }
        .autocorrectionDisabled()
        .focused($isFocused)
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store, isFocused: $isFocused)
        .onChange(of: text) { _ in isEdited = true }
    }
}

struct EditorSecureRow: View {
    private let title: String
    @Binding private var text: String
    private let prompt: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore

    @State private var isEdited = false
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, row: EditorRow, store: ConnectionEditorStore) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.row = row
        self.store = store
    }

    var body: some View {
        SecureField(text: $text, prompt: prompt.map { Text(verbatim: $0) }) {
            EditorRowLabel(title, row: row, store: store, isEdited: isEdited)
        }
        .focused($isFocused)
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store, isFocused: $isFocused)
        .onChange(of: text) { _ in isEdited = true }
    }
}
