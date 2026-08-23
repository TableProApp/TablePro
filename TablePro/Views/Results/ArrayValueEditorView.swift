//
//  ArrayValueEditorView.swift
//  TablePro
//
//  Ordered per-element editor for PostgreSQL array columns.
//

import SwiftUI
import TableProPluginKit

struct ArrayValueEditorView: View {
    let allowedValues: [String]
    let isNullable: Bool
    let delimiter: Character
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var rows: [ArrayEditorRow]
    @State private var isNull: Bool
    @State private var isEditingRawText: Bool
    @State private var rawText: String

    init(
        initialElements: [PostgresArrayElement]?,
        allowedValues: [String],
        isNullable: Bool,
        delimiter: Character = PostgresArrayLiteralCodec.defaultDelimiter,
        onCommit: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.allowedValues = allowedValues
        self.isNullable = isNullable
        self.delimiter = delimiter
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        let elements = initialElements ?? []
        _rows = State(initialValue: ArrayValueEditorModel.rows(from: elements))
        _isNull = State(initialValue: initialElements == nil)
        _isEditingRawText = State(initialValue: false)
        _rawText = State(initialValue: PostgresArrayLiteralCodec.serialize(elements, delimiter: delimiter))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEditingRawText {
                rawTextEditor
            } else {
                elementList
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isNullable {
                Toggle("NULL", isOn: $isNull)
                    .toggleStyle(.checkbox)
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
        .disabled(isNull)
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
            Button {
                rows = ArrayValueEditorModel.removing(rows, id: row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
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
        .font(.system(.callout, design: .monospaced))
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
                    .font(.system(.callout, design: .monospaced))
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
        }
    }

    private func reorderButtons(for row: ArrayEditorRow) -> some View {
        HStack(spacing: 2) {
            Button {
                rows = ArrayValueEditorModel.moved(rows, id: row.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(rows.first?.id == row.id)
            .help(Text("Move Up"))

            Button {
                rows = ArrayValueEditorModel.moved(rows, id: row.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
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
                .font(.system(.callout, design: .monospaced))
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
        .disabled(isNull)
        .opacity(isNull ? 0.4 : 1)
    }

    private var footer: some View {
        HStack {
            if !isEditingRawText {
                Button {
                    rows.append(ArrayEditorRow(element: defaultNewElement))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isNull)
                .help(Text("Add Element"))
            }
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { commitAndDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var defaultNewElement: PostgresArrayElement {
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
            isEditingRawText = false
            return
        }
        rawText = ArrayValueEditorModel.literal(from: rows, delimiter: delimiter)
        isEditingRawText = true
    }

    private func commitAndDismiss() {
        guard !isNull else {
            onCommit(nil)
            onDismiss()
            return
        }
        let value = isEditingRawText
            ? rawText
            : ArrayValueEditorModel.literal(from: rows, delimiter: delimiter)
        onCommit(value)
        onDismiss()
    }
}
