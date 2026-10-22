//
//  ERDiagramEditSheets.swift
//  TablePro
//

import SwiftUI

extension ERDiagramForeignKeyDraft {
    // The referenced column follows the referenced table, so both change in one write.
    func referencing(_ table: String, column: String) -> ERDiagramForeignKeyDraft {
        var draft = self
        draft.referencedTable = table
        draft.referencedColumn = column
        return draft
    }
}

struct ERDiagramForeignKeySheet: View {
    @State private var draft: ERDiagramForeignKeyDraft
    private let tables: [String]
    private let columns: (String) -> [String]
    private let defaultReferencedColumn: (String) -> String
    private let isNameTaken: (String) -> Bool
    private let dialect: ForeignKeyDialect
    private let onAdd: (ERDiagramForeignKeyDraft) -> Void
    private let onCancel: () -> Void

    init(
        draft: ERDiagramForeignKeyDraft,
        tables: [String],
        columns: @escaping (String) -> [String],
        defaultReferencedColumn: @escaping (String) -> String,
        isNameTaken: @escaping (String) -> Bool,
        dialect: ForeignKeyDialect,
        onAdd: @escaping (ERDiagramForeignKeyDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.tables = tables
        self.columns = columns
        self.defaultReferencedColumn = defaultReferencedColumn
        self.isNameTaken = isNameTaken
        self.dialect = dialect
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        !trimmedName.isEmpty && isNameTaken(trimmedName)
    }

    private var canAdd: Bool {
        !draft.column.isEmpty && !draft.referencedTable.isEmpty && !draft.referencedColumn.isEmpty
            && !trimmedName.isEmpty && !nameIsTaken
    }

    private var referencedTable: Binding<String> {
        Binding(
            get: { draft.referencedTable },
            set: { draft = draft.referencing($0, column: defaultReferencedColumn($0)) }
        )
    }

    private var deleteActions: [EditableForeignKeyDefinition.ReferentialAction] {
        dialect.deleteActions.isEmpty ? [.noAction] : dialect.deleteActions
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(String(localized: "Table"), value: draft.table)
                    Picker(String(localized: "Column"), selection: $draft.column) {
                        ForEach(columns(draft.table), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section(String(localized: "References")) {
                    Picker(String(localized: "Table"), selection: referencedTable) {
                        ForEach(tables, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(String(localized: "Column"), selection: $draft.referencedColumn) {
                        ForEach(columns(draft.referencedTable), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    TextField(String(localized: "Constraint Name"), text: $draft.name)
                    Picker(String(localized: "On Delete"), selection: $draft.onDelete) {
                        ForEach(deleteActions, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    }
                    if !dialect.updateActions.isEmpty {
                        Picker(String(localized: "On Update"), selection: $draft.onUpdate) {
                            ForEach(dialect.updateActions, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                        }
                    }
                } footer: {
                    if nameIsTaken {
                        Text(String(format: String(localized: "A foreign key named “%@” already exists."), trimmedName))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add Foreign Key")) {
                    var staged = draft
                    staged.name = trimmedName
                    onAdd(staged)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding()
        }
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("er-diagram-foreign-key-sheet")
    }
}

struct ERDiagramColumnSheet: View {
    enum Mode: Equatable {
        case add
        case rename(String)
    }

    private let table: String
    private let mode: Mode
    private let databaseType: DatabaseType
    private let isNameTaken: (String) -> Bool
    private let onAdd: (EditableColumnDefinition) -> Void
    private let onRename: (String) -> Void
    private let onCancel: () -> Void

    @State private var name: String
    @State private var dataType = ""
    @State private var isNullable = true
    @State private var defaultValue = ""
    @State private var isPickingType = false

    init(
        table: String,
        mode: Mode,
        databaseType: DatabaseType,
        isNameTaken: @escaping (String) -> Bool,
        onAdd: @escaping (EditableColumnDefinition) -> Void,
        onRename: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.table = table
        self.mode = mode
        self.databaseType = databaseType
        self.isNameTaken = isNameTaken
        self.onAdd = onAdd
        self.onRename = onRename
        self.onCancel = onCancel
        if case .rename(let current) = mode {
            _name = State(initialValue: current)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        !trimmedName.isEmpty && isNameTaken(trimmedName)
    }

    private var canCommit: Bool {
        guard !trimmedName.isEmpty, !nameIsTaken else { return false }
        switch mode {
        case .add:
            return !dataType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .rename(let current):
            return trimmedName != current
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(String(localized: "Table"), value: table)
                    TextField(String(localized: "Name"), text: $name)
                    if mode == .add {
                        LabeledContent(String(localized: "Type")) {
                            HStack(spacing: 4) {
                                TextField(String(localized: "Type"), text: $dataType)
                                    .labelsHidden()
                                Button {
                                    isPickingType = true
                                } label: {
                                    Image(systemName: "list.bullet")
                                }
                                .help(String(localized: "Choose a Type"))
                                .accessibilityLabel(String(localized: "Choose a Type"))
                                .popover(isPresented: $isPickingType, arrowEdge: .bottom) {
                                    TypePickerContentView(
                                        databaseType: databaseType,
                                        currentValue: dataType,
                                        onCommit: { dataType = $0 },
                                        onDismiss: { isPickingType = false }
                                    )
                                }
                            }
                        }
                        Toggle(String(localized: "Allow NULL"), isOn: $isNullable)
                        TextField(String(localized: "Default"), text: $defaultValue, prompt: Text(String(localized: "None")))
                    }
                } footer: {
                    if nameIsTaken {
                        Text(String(format: String(localized: "“%@” already has a column with that name."), table))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(commitTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
            .padding()
        }
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("er-diagram-column-sheet")
    }

    private var commitTitle: String {
        switch mode {
        case .add: String(localized: "Add Column")
        case .rename: String(localized: "Rename")
        }
    }

    private func commit() {
        switch mode {
        case .add:
            var column = EditableColumnDefinition.placeholder()
            column.name = trimmedName
            column.dataType = dataType.trimmingCharacters(in: .whitespacesAndNewlines)
            column.isNullable = isNullable
            let trimmedDefault = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            column.defaultValue = trimmedDefault.isEmpty ? nil : trimmedDefault
            onAdd(column)
        case .rename:
            onRename(trimmedName)
        }
    }
}
