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

enum EditorSecretKind {
    case password
    case passphrase
    case secret

    var showTitle: String {
        switch self {
        case .password: String(localized: "Show password")
        case .passphrase: String(localized: "Show passphrase")
        case .secret: String(localized: "Show secret")
        }
    }

    var hideTitle: String {
        switch self {
        case .password: String(localized: "Hide password")
        case .passphrase: String(localized: "Hide passphrase")
        case .secret: String(localized: "Hide secret")
        }
    }
}

// NSSecureTextField has no reveal of its own, so the eye button swaps in a plain field.
struct EditorRevealableSecureRow: View {
    private let title: String
    @Binding private var text: String
    private let kind: EditorSecretKind
    private let requiresAuthentication: Bool
    private let prompt: String?
    private let subtitle: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore

    @StateObject private var reveal = SecretReveal()
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        text: Binding<String>,
        kind: EditorSecretKind,
        requiresAuthentication: Bool,
        prompt: String? = nil,
        subtitle: String? = nil,
        row: EditorRow,
        store: ConnectionEditorStore
    ) {
        self.title = title
        _text = text
        self.kind = kind
        self.requiresAuthentication = requiresAuthentication
        self.prompt = prompt
        self.subtitle = subtitle
        self.row = row
        self.store = store
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                field
                    .labelsHidden()
                    .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
                    .focused($isFocused)
                    .accessibilityIdentifier(row.accessibilityIdentifier)

                Button {
                    Task { await reveal.setRevealed(!reveal.isRevealed, requiresAuthentication: requiresAuthentication) }
                } label: {
                    Image(systemName: reveal.isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealTitle)
                .accessibilityLabel(revealTitle)
                .accessibilityIdentifier("\(row.accessibilityIdentifier)-reveal")
            }
        } label: {
            EditorRowLabel(title, row: row, store: store, subtitle: subtitle)
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
    }

    private var revealTitle: String {
        reveal.isRevealed ? kind.hideTitle : kind.showTitle
    }

    @ViewBuilder
    private var field: some View {
        let tracked = store.tracking($text, row: row)
        let prompt = Text(verbatim: EditorFieldPrompt.text(prompt, row: row, store: store))
        if reveal.isRevealed {
            TextField(text: tracked, prompt: prompt) { Text(verbatim: title) }
                .autocorrectionDisabled()
        } else {
            SecureField(text: tracked, prompt: prompt) { Text(verbatim: title) }
        }
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
