//
//  RowDetailView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct RowDetailView: View {
    let columns: [ColumnInfo]
    @State private var rows: [[String?]]
    let table: TableInfo?
    let session: ConnectionSession?
    let columnDetails: [ColumnInfo]
    let databaseType: DatabaseType
    let safeModeLevel: SafeModeLevel
    let foreignKeys: [ForeignKeyInfo]
    var onSaved: (() -> Void)?

    @State private var currentIndex: Int
    @State private var isEditing = false
    @State private var editedValues: [String?] = []
    @State private var isSaving = false
    @State private var operationError: AppError?
    @State private var showOperationError = false
    @State private var showSaveSuccess = false
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var hapticSelection = 0
    @State private var showShareSheet = false
    @State private var shareText = ""

    init(
        columns: [ColumnInfo],
        rows: [[String?]],
        initialIndex: Int,
        table: TableInfo? = nil,
        session: ConnectionSession? = nil,
        columnDetails: [ColumnInfo] = [],
        databaseType: DatabaseType = .sqlite,
        safeModeLevel: SafeModeLevel = .off,
        foreignKeys: [ForeignKeyInfo] = [],
        onSaved: (() -> Void)? = nil
    ) {
        self.columns = columns
        _rows = State(initialValue: rows)
        self.table = table
        self.session = session
        self.columnDetails = columnDetails
        self.databaseType = databaseType
        self.safeModeLevel = safeModeLevel
        self.foreignKeys = foreignKeys
        self.onSaved = onSaved
        _currentIndex = State(initialValue: initialIndex)
    }

    private var currentRow: [String?] {
        guard currentIndex >= 0, currentIndex < rows.count else { return [] }
        return rows[currentIndex]
    }

    private var isView: Bool {
        guard let table else { return false }
        return table.type == .view || table.type == .materializedView
    }

    private var canEdit: Bool {
        table != nil && session != nil && !columnDetails.isEmpty && !isView
            && !safeModeLevel.blocksWrites
            && columnDetails.contains(where: { $0.isPrimaryKey })
    }

    var body: some View {
        Group {
            if isEditing {
                rowContent(at: currentIndex)
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(rows.indices), id: \.self) { index in
                        rowContent(at: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .onChange(of: currentIndex) {
            hapticSelection += 1
        }
        .overlay(alignment: .bottom) {
            if showSaveSuccess {
                Label("Row updated", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding()
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(table?.name ?? String(format: String(localized: "Row %d of %d"), currentIndex + 1, rows.count))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Share") {
                        ForEach(ExportFormat.allCases) { format in
                            Button {
                                shareText = ClipboardExporter.exportRow(
                                    columns: columns, row: currentRow,
                                    format: format, tableName: table?.name
                                )
                                showShareSheet = true
                            } label: {
                                Label(format.rawValue, systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    Section("Copy to Clipboard") {
                        ForEach(ExportFormat.allCases) { format in
                            Button {
                                let text = ClipboardExporter.exportRow(
                                    columns: columns, row: currentRow,
                                    format: format, tableName: table?.name
                                )
                                ClipboardExporter.copyToClipboard(text)
                            } label: {
                                Label(format.rawValue, systemImage: "doc.on.clipboard")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if canEdit {
                    if isEditing {
                        Button {
                            Task { await saveChanges() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(isSaving)
                    } else {
                        Button("Edit") { startEditing() }
                    }
                }
            }

            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelEditing() }
                        .disabled(isSaving)
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    currentIndex -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentIndex <= 0 || isEditing)

                Spacer()

                Text("\(currentIndex + 1) of \(rows.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()

                Spacer()

                Button {
                    currentIndex += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentIndex >= rows.count - 1 || isEditing)
            }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
        .sensoryFeedback(.selection, trigger: hapticSelection)
        .alert(operationError?.title ?? "Error", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let recovery = operationError?.recovery {
                Text(verbatim: "\(operationError?.message ?? "") \(recovery)")
            } else {
                Text(operationError?.message ?? "")
            }
        }
        .sheet(item: $fkPreviewItem) { item in
            FKPreviewView(
                fk: item.fk,
                value: item.value,
                session: session,
                databaseType: databaseType
            )
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(items: [shareText])
        }
    }

    @ViewBuilder
    private func rowContent(at rowIndex: Int) -> some View {
        let row = rowIndex >= 0 && rowIndex < rows.count ? rows[rowIndex] : []
        let values = isEditing ? editedValues : row
        List {
            ForEach(Array(zip(columns, values).enumerated()), id: \.offset) { index, pair in
                let (column, value) = pair
                let isPK = columnDetail(for: column.name)?.isPrimaryKey ?? column.isPrimaryKey
                Section {
                    if isEditing && !isPK {
                        editableField(index: index, value: value)
                    } else {
                        fieldContent(value: value)
                            .contextMenu {
                                if let value {
                                    Button {
                                        UIPasteboard.general.string = value
                                    } label: {
                                        Label("Copy Value", systemImage: "doc.on.doc")
                                    }
                                }
                                Button {
                                    UIPasteboard.general.string = column.name
                                } label: {
                                    Label("Copy Column Name", systemImage: "textformat")
                                }
                            }
                        if let fk = foreignKeys.first(where: { $0.column == column.name }), let value {
                            Button {
                                fkPreviewItem = FKPreviewItem(fk: fk, value: value)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.footnote)
                                    Text("\(fk.referencedTable).\(fk.referencedColumn)")
                                        .font(.footnote)
                                }
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        if isPK {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(column.name)

                        if isEditing && isPK {
                            Text("read-only")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(column.typeName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private func editableField(index: Int, value: String?) -> some View {
        let binding = Binding<String>(
            get: {
                guard index < editedValues.count else { return "" }
                return editedValues[index] ?? ""
            },
            set: { newValue in
                guard index < editedValues.count else { return }
                editedValues[index] = newValue
            }
        )

        let isNull = index < editedValues.count ? editedValues[index] == nil : true

        return HStack {
            if isNull {
                Text("NULL")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                TextField("Value", text: binding)
                    .font(.body)
            }

            Button {
                guard index < editedValues.count else { return }
                if editedValues[index] == nil {
                    editedValues[index] = ""
                } else {
                    editedValues[index] = nil
                }
            } label: {
                Text("NULL")
                    .font(.caption2)
                    .foregroundStyle(isNull ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isNull ? Color.accentColor : Color(.systemFill))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func fieldContent(value: String?) -> some View {
        if let value {
            Text(verbatim: value)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(verbatim: "NULL")
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private func columnDetail(for name: String) -> ColumnInfo? {
        columnDetails.first { $0.name == name }
    }

    private func startEditing() {
        editedValues = currentRow
        isEditing = true
        showSaveSuccess = false
    }

    private func cancelEditing() {
        isEditing = false
        editedValues = []
        showSaveSuccess = false
    }

    private func saveChanges() async {
        guard let session, let table else { return }

        isSaving = true
        defer { isSaving = false }

        let pkValues: [(column: String, value: String)] = columnDetails.compactMap { col in
            guard col.isPrimaryKey else { return nil }
            let colIndex = columns.firstIndex(where: { $0.name == col.name })
            guard let colIndex, colIndex < currentRow.count, let value = currentRow[colIndex] else { return nil }
            return (column: col.name, value: value)
        }

        guard !pkValues.isEmpty else {
            operationError = AppError(category: .config, title: "Cannot Save", message: "No primary key values found.", recovery: "This table needs a primary key to identify the row.", underlying: nil)
            showOperationError = true
            return
        }

        var changes: [(column: String, value: String?)] = []
        for (index, column) in columns.enumerated() {
            let isPK = columnDetail(for: column.name)?.isPrimaryKey ?? column.isPrimaryKey
            if isPK { continue }
            guard index < editedValues.count else { continue }
            let oldValue = index < currentRow.count ? currentRow[index] : nil
            let newValue = editedValues[index]
            if oldValue != newValue {
                changes.append((column: column.name, value: newValue))
            }
        }

        guard !changes.isEmpty else {
            isEditing = false
            editedValues = []
            return
        }

        let sql = SQLBuilder.buildUpdate(
            table: table.name,
            type: databaseType,
            changes: changes,
            primaryKeys: pkValues
        )

        do {
            _ = try await session.driver.execute(query: sql)
            guard currentIndex >= 0, currentIndex < rows.count else { return }
            rows[currentIndex] = editedValues
            isEditing = false
            showSaveSuccess = true
            hapticSuccess.toggle()
            onSaved?()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { showSaveSuccess = false }
            }
        } catch {
            let context = ErrorContext(operation: "saveChanges", databaseType: databaseType)
            operationError = ErrorClassifier.classify(error, context: context)
            showOperationError = true
            hapticError.toggle()
        }
    }
}
