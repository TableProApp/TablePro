//
//  EditorOptionalNumberRow.swift
//  TablePro
//

import SwiftUI

// An Int? setting: an empty field means the default, which the prompt shows. Every whole number reaches the draft as
// it is typed, so the engine's range issue shows under the label and Save never misses the last keystroke.
struct EditorOptionalNumberRow: View {
    private let title: String
    @Binding private var value: Int?
    private let defaultValue: Int?
    private let range: ClosedRange<Int>
    private let unit: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let subtitle: String?
    private let prompt: String?

    @State private var text: String
    @State private var isEdited = false
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        value: Binding<Int?>,
        defaultValue: Int?,
        range: ClosedRange<Int>,
        unit: String?,
        row: EditorRow,
        store: ConnectionEditorStore,
        subtitle: String? = nil,
        prompt: String? = nil
    ) {
        self.title = title
        _value = value
        self.defaultValue = defaultValue
        self.range = range
        self.unit = unit
        self.row = row
        self.store = store
        self.subtitle = subtitle
        self.prompt = prompt
        _text = State(initialValue: Self.text(for: value.wrappedValue))
    }

    var body: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(text: $text, prompt: promptText.map { Text(verbatim: $0) }) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: prompt == nil ? 72 : 104)
                .focused($isFocused)
                .accessibilityIdentifier(row.accessibilityIdentifier)
                .onSubmit(settle)

                if let unit {
                    Text(verbatim: unit)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            if let localError {
                Text(verbatim: title)
                NoticeLabel(localError, severity: .error)
            } else {
                EditorRowLabel(title, row: row, store: store, subtitle: subtitle, isEdited: isEdited)
            }
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
        .onChange(of: text) { newText in
            isEdited = true
            write(newText)
        }
        .onChange(of: value) { newValue in
            guard !isFocused, Self.parse(text) != .some(newValue) else { return }
            text = Self.text(for: newValue)
        }
        .onChange(of: isFocused) { focused in
            if !focused { settle() }
        }
    }

    private var promptText: String? {
        prompt ?? defaultValue.map { SettingsFormat.identifier($0) }
    }

    // Only text that is not a whole number stays local; the engine owns the range message when it has one.
    private var localError: String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let number = SettingsIntegerInput.parse(trimmed) else {
            return String(localized: "Enter a whole number.")
        }
        guard !range.contains(number), store.issue(for: row) == nil else { return nil }
        return String(
            format: String(localized: "Enter a number from %@ to %@."),
            SettingsFormat.identifier(range.lowerBound),
            SettingsFormat.identifier(range.upperBound)
        )
    }

    private func write(_ newText: String) {
        switch Self.parse(newText) {
        case .some(let parsed):
            if parsed != value { value = parsed }
        case .none:
            break
        }
    }

    // Text that never parsed goes back to the stored value when the field is left.
    private func settle() {
        if Self.parse(text) == nil {
            text = Self.text(for: value)
        }
    }

    // nil: not a number; .some(nil): empty, the default.
    private static func parse(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let number = SettingsIntegerInput.parse(trimmed) else { return nil }
        return .some(number)
    }

    private static func text(for value: Int?) -> String {
        value.map { SettingsFormat.identifier($0) } ?? ""
    }
}
