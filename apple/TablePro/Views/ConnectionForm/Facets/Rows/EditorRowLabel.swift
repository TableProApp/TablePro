//
//  EditorRowLabel.swift
//  TablePro
//

import SwiftUI

// A row's title, with its issue as the subtitle once the person has touched the field or tried to save.
struct EditorRowLabel: View {
    private let title: String
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let subtitle: String?
    private let isEdited: Bool

    init(
        _ title: String,
        row: EditorRow,
        store: ConnectionEditorStore,
        subtitle: String? = nil,
        isEdited: Bool = false
    ) {
        self.title = title
        self.row = row
        self.store = store
        self.subtitle = subtitle
        self.isEdited = isEdited
    }

    var body: some View {
        Text(verbatim: title)
        if let issue = EditorIssueVisibility.issue(for: row, in: store, isEdited: isEdited) {
            NoticeLabel(issue.message, severity: issue.severity == .error ? .error : .warning)
        } else if let subtitle {
            Text(verbatim: subtitle)
        }
    }
}

@MainActor
enum EditorIssueVisibility {
    // A pristine new form is never painted red: its empty required fields show only their prompts until an edit or a
    // Save. A focus request does not reveal, since the editor also uses one to place the cursor when it opens.
    static func issue(for row: EditorRow, in store: ConnectionEditorStore, isEdited: Bool) -> FieldIssue? {
        guard let issue = store.issue(for: row) else { return nil }
        let revealed = isEdited || !store.isNew || store.saveError != nil
        return revealed ? issue : nil
    }
}

private struct EditorRowFocusModifier: ViewModifier {
    let row: EditorRow
    @ObservedObject var store: ConnectionEditorStore
    let isFocused: FocusState<Bool>.Binding

    @State private var handledToken: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { apply(store.focusRequest) }
            .onChange(of: store.focusRequest) { apply($0) }
    }

    // Deferred a turn: a facet that was just selected is not in the window yet when the request lands.
    private func apply(_ request: FocusRequest?) {
        guard let request, request.row == row, request.token != handledToken else { return }
        handledToken = request.token
        DispatchQueue.main.async {
            isFocused.wrappedValue = true
        }
    }
}

extension View {
    func editorRowFocus(_ row: EditorRow, store: ConnectionEditorStore, isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(EditorRowFocusModifier(row: row, store: store, isFocused: isFocused))
    }
}
