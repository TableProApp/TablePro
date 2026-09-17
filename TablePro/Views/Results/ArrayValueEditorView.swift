//
//  ArrayValueEditorView.swift
//  TablePro
//
//  Ordered per-element editor for PostgreSQL array columns.
//

import SwiftUI
import TableProPluginKit

struct ArrayValueEditorView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let allowedValues: [String]
    let isNullable: Bool
    let delimiter: Character
    let elementEditor: ArrayElementEditor
    let isReadOnly: Bool
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var rows: [ArrayEditorRow]
    @State private var isNull: Bool
    @State private var isEditingRawText: Bool
    @State private var rawText: String
    @State private var selection: UUID?

    /// Takes the stored literal rather than parsed elements, so the editor is total over what a
    /// column can hold. A literal the list cannot represent, a multi-dimensional one or one
    /// carrying explicit bounds, opens in raw text mode over its own text instead of silently
    /// becoming an empty array that the next OK would write over the user's value.
    init(
        literal: String?,
        allowedValues: [String],
        isNullable: Bool,
        delimiter: Character = PostgresArrayLiteralCodec.defaultDelimiter,
        elementEditor: ArrayElementEditor = .scalar,
        isReadOnly: Bool = false,
        onCommit: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.allowedValues = allowedValues
        self.isNullable = isNullable
        self.delimiter = delimiter
        self.elementEditor = elementEditor
        self.isReadOnly = isReadOnly
        self.onCommit = onCommit
        self.onDismiss = onDismiss

        let stored = literal ?? ""
        let parsed = stored.isEmpty ? [] : PostgresArrayLiteralCodec.parse(stored, delimiter: delimiter)
        _rows = State(initialValue: ArrayValueEditorModel.rows(from: parsed ?? []))
        _isNull = State(initialValue: literal == nil)
        _isEditingRawText = State(initialValue: parsed == nil)
        _rawText = State(
            initialValue: parsed.map { PostgresArrayLiteralCodec.serialize($0, delimiter: delimiter) } ?? stored
        )
        _selection = State(initialValue: nil)
    }

    private var isJsonEditor: Bool { elementEditor == .json }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEditingRawText {
                rawTextEditor
            } else if isJsonEditor {
                jsonElementEditor
            } else {
                elementList
            }
            Divider()
            footer
        }
        .modifier(ArrayEditorSizing(isJsonEditor: isJsonEditor))
        .onExitCommand(perform: onDismiss)
    }

    private var jsonElementEditor: some View {
        ArrayJsonElementEditor(rows: $rows, selection: $selection, isReadOnly: isReadOnly)
            .disabled(isNull)
            .opacity(isNull ? 0.4 : 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isNullable {
                Toggle("NULL", isOn: $isNull)
                    .toggleStyle(.checkbox)
                    .disabled(isReadOnly)
            }
            Text(elementCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isEditingRawText ? "Edit as List" : "Edit as Text") {
                toggleRawTextEditing()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var elementList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    elementRow(for: row)
                }
                if rows.isEmpty {
                    Text("Empty array")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .padding(12)
        }
        .disabled(isNull || isReadOnly)
        .opacity(isNull ? 0.4 : 1)
    }

    @ViewBuilder
    private func elementRow(for row: ArrayEditorRow) -> some View {
        HStack(spacing: 6) {
            if allowedValues.isEmpty {
                scalarField(for: row)
            } else {
                labelPicker(for: row)
            }
            reorderButtons(for: row)
            Button("Remove Element", systemImage: "minus.circle") {
                rows = ArrayValueEditorModel.removing(rows, id: row.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(Text("Remove Element"))
        }
    }

    @ViewBuilder
    private func scalarField(for row: ArrayEditorRow) -> some View {
        let element = binding(for: row.id)
        TextField(
            "",
            text: Binding(
                get: {
                    guard case .value(let value) = element.wrappedValue else { return "" }
                    return value
                },
                set: { element.wrappedValue = .value($0) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .font(themeEngine.valueFontSwiftUI)
        .disabled(element.wrappedValue == .null)
        Toggle("NULL", isOn: Binding(
            get: { element.wrappedValue == .null },
            set: { element.wrappedValue = $0 ? .null : .value("") }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    @ViewBuilder
    private func labelPicker(for row: ArrayEditorRow) -> some View {
        let element = binding(for: row.id)
        let options = ArrayValueEditorModel.pickerOptions(for: row.element, allowedValues: allowedValues)
        Picker(
            "",
            selection: Binding(
                get: { ArrayValueEditorModel.selectionIndex(for: element.wrappedValue, in: options) },
                set: { element.wrappedValue = ArrayValueEditorModel.element(atSelectionIndex: $0, in: options) }
            )
        ) {
            ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                Text(option)
                    .font(themeEngine.valueFontSwiftUI)
                    .tag(optionIndex)
            }
            Text("NULL").italic().tag(options.count)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        if ArrayValueEditorModel.isDriftedValue(row.element, allowedValues: allowedValues) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(Text("This value is not one of the type's current labels"))
                .accessibilityLabel(Text("This value is not one of the type's current labels"))
        }
    }

    private func reorderButtons(for row: ArrayEditorRow) -> some View {
        HStack(spacing: 2) {
            Button("Move Up", systemImage: "chevron.up") {
                rows = ArrayValueEditorModel.moved(rows, id: row.id, by: -1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(rows.first?.id == row.id)
            .help(Text("Move Up"))

            Button("Move Down", systemImage: "chevron.down") {
                rows = ArrayValueEditorModel.moved(rows, id: row.id, by: 1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(rows.last?.id == row.id)
            .help(Text("Move Down"))
        }
    }

    private func binding(for id: UUID) -> Binding<PostgresArrayElement> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.element ?? .null },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index].element = newValue
            }
        )
    }

    private var rawTextEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $rawText)
                .font(themeEngine.valueFontSwiftUI)
                .frame(minHeight: 90)
            if PostgresArrayLiteralCodec.parse(rawText, delimiter: delimiter) == nil {
                Label {
                    Text("This is not a value the list editor can read back.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .disabled(isNull || isReadOnly)
        .opacity(isNull ? 0.4 : 1)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if !isEditingRawText {
                Button("Add Element", systemImage: "plus", action: addElement)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isNull || isReadOnly)
                    .help(Text("Add Element"))
                if isJsonEditor {
                    selectionControls
                }
            }
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { commitAndDismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(isReadOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The JSON element list is a master list, so its add, remove and reorder act on the selection
    /// from one place rather than repeating four controls on every row the way a compact list of
    /// one-line fields can afford to.
    private var selectionControls: some View {
        Group {
            Button("Remove Element", systemImage: "minus", action: removeSelected)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isNull || isReadOnly || selection == nil)
                .help(Text("Remove Element"))

            Button("Move Up", systemImage: "chevron.up") { moveSelected(by: -1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isNull || isReadOnly || selectedIndex == nil || selectedIndex == 0)
                .help(Text("Move Up"))

            Button("Move Down", systemImage: "chevron.down") { moveSelected(by: 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isNull || isReadOnly || selectedIndex == nil || selectedIndex == rows.count - 1)
                .help(Text("Move Down"))
        }
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return rows.firstIndex { $0.id == selection }
    }

    private func addElement() {
        let row = ArrayEditorRow(element: defaultNewElement)
        rows.append(row)
        if isJsonEditor { selection = row.id }
    }

    private func removeSelected() {
        guard let selection else { return }
        let index = selectedIndex
        rows = ArrayValueEditorModel.removing(rows, id: selection)
        self.selection = index.map { min($0, rows.count - 1) }.flatMap { $0 >= 0 ? rows[$0].id : nil }
    }

    private func moveSelected(by offset: Int) {
        guard let selection else { return }
        rows = ArrayValueEditorModel.moved(rows, id: selection, by: offset)
    }

    private var defaultNewElement: PostgresArrayElement {
        if isJsonEditor { return .value("{}") }
        guard let first = allowedValues.first else { return .value("") }
        return .value(first)
    }

    private var elementCountLabel: String {
        guard !isNull else { return String(localized: "NULL") }
        let count = isEditingRawText
            ? (PostgresArrayLiteralCodec.parse(rawText, delimiter: delimiter)?.count ?? rows.count)
            : rows.count
        guard count > 0 else { return String(localized: "Empty array") }
        return String(format: String(localized: "%d elements"), count)
    }

    private func toggleRawTextEditing() {
        if isEditingRawText {
            guard let parsed = PostgresArrayLiteralCodec.parse(rawText, delimiter: delimiter) else { return }
            rows = ArrayValueEditorModel.rows(from: parsed)
            selection = rows.first?.id
            isEditingRawText = false
            return
        }
        rawText = committedLiteral
        isEditingRawText = true
    }

    private func commitAndDismiss() {
        guard !isNull else {
            onCommit(nil)
            onDismiss()
            return
        }
        onCommit(isEditingRawText ? rawText : committedLiteral)
        onDismiss()
    }

    private var committedLiteral: String {
        ArrayValueEditorModel.literal(from: rows, delimiter: delimiter, elementEditor: elementEditor)
    }
}

/// A list of one-line fields can size itself to its rows; a list with a document editor under it
/// cannot, because the editor has no height of its own to offer. The JSON editor therefore takes a
/// definite range, the way the JSON cell popover already does, and only the scalar list sizes to
/// fit.
private struct ArrayEditorSizing: ViewModifier {
    let isJsonEditor: Bool

    func body(content: Content) -> some View {
        if isJsonEditor {
            content
                .frame(width: 620)
                .frame(minHeight: 420, maxHeight: 560)
        } else {
            content
                .frame(width: 320)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
