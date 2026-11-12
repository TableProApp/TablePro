//
//  ERDiagramEditSheets.swift
//  TablePro
//

import SwiftUI

struct ERDiagramForeignKeySheet: View {
    @State private var draft: ERDiagramForeignKeyDraft
    @State private var selection: Set<UUID> = []
    private let tables: [String]
    private let columns: (String) -> [String]
    private let referencedKeyColumns: (String) -> [String]
    private let isNameTaken: (String) -> Bool
    private let dialect: ForeignKeyDialect
    private let onAdd: (ERDiagramForeignKeyDraft) -> Void
    private let onCancel: () -> Void

    init(
        draft: ERDiagramForeignKeyDraft,
        tables: [String],
        columns: @escaping (String) -> [String],
        referencedKeyColumns: @escaping (String) -> [String],
        isNameTaken: @escaping (String) -> Bool,
        dialect: ForeignKeyDialect,
        onAdd: @escaping (ERDiagramForeignKeyDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.tables = tables
        self.columns = columns
        self.referencedKeyColumns = referencedKeyColumns
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
        draft.issue == nil && !draft.referencedTable.isEmpty && !trimmedName.isEmpty && !nameIsTaken
    }

    private var referencedTable: Binding<String> {
        Binding(
            get: { draft.referencedTable },
            set: { table in
                draft = draft.referencing(
                    table, keyColumns: referencedKeyColumns(table), sourceColumns: columns(draft.table)
                )
                selection = []
            }
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
                }
                Section(String(localized: "References")) {
                    Picker(String(localized: "Table"), selection: referencedTable) {
                        ForEach(tables, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    pairList
                } header: {
                    Text(String(localized: "Column → Referenced Column"))
                } footer: {
                    if let issue = draft.issue {
                        Text(issue.message)
                            .foregroundStyle(.secondary)
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
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("er-diagram-foreign-key-sheet")
    }

    // MARK: - Column pairs

    private var pairList: some View {
        List(selection: $selection) {
            ForEach(draft.pairs) { pair in
                ERDiagramColumnPairRow(
                    column: columnBinding(for: pair.id),
                    referencedColumn: referencedColumnBinding(for: pair.id),
                    columns: columns(draft.table),
                    referencedColumns: columns(draft.referencedTable),
                    onMoveUp: { move(pair.id, by: -1) },
                    onMoveDown: { move(pair.id, by: 1) }
                )
                .tag(pair.id)
            }
            .onMove { source, destination in
                draft = draft.movingPairs(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: listHeight)
        .onDeleteCommand { removeSelection() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    AddRemoveControlGroup(
                        addLabel: String(localized: "Add Column Pair"),
                        removeLabel: String(localized: "Remove Column Pair"),
                        canRemove: canRemoveSelection,
                        addIdentifier: "er-diagram-foreign-key-add-pair",
                        removeIdentifier: "er-diagram-foreign-key-remove-pair",
                        onAdd: addPair,
                        onRemove: removeSelection
                    )
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(.bar)
        }
    }

    private let rowHeight: CGFloat = 26
    private let buttonBarHeight: CGFloat = 32

    // No cap: a List in a grouped Form never scrolls, so it shows every pair and the Form scrolls.
    private var listHeight: CGFloat {
        CGFloat(max(draft.pairs.count, 2)) * rowHeight + buttonBarHeight + 8
    }

    private var canRemoveSelection: Bool {
        !selection.isEmpty && selection.count < draft.pairs.count
    }

    private func columnBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { draft.pairs.first { $0.id == id }?.column ?? "" },
            set: { draft = draft.settingColumn($0, of: id) }
        )
    }

    private func referencedColumnBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { draft.pairs.first { $0.id == id }?.referencedColumn ?? "" },
            set: { draft = draft.settingReferencedColumn($0, of: id) }
        )
    }

    private func addPair() {
        draft = draft.addingPair()
        if let added = draft.pairs.last?.id {
            selection = [added]
        }
    }

    private func removeSelection() {
        guard canRemoveSelection else { return }
        draft = draft.removingPairs(selection)
        selection = []
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.pairs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.pairs.indices.contains(target) else { return }
        draft = draft.movingPairs(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
    }
}

private struct ERDiagramColumnPairRow: View {
    @Binding var column: String
    @Binding var referencedColumn: String
    let columns: [String]
    let referencedColumns: [String]
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            picker(String(localized: "Column"), selection: $column, options: columns)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            picker(String(localized: "Referenced Column"), selection: $referencedColumn, options: referencedColumns)
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button(String(localized: "Move Up"), action: onMoveUp)
            Button(String(localized: "Move Down"), action: onMoveDown)
        }
    }

    // A blank side names nothing until it is chosen, so it gets an item of its own rather than an invalid selection.
    private func picker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            if selection.wrappedValue.isEmpty {
                Text(String(localized: "None")).tag("")
            }
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel(title)
        .frame(maxWidth: .infinity)
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
