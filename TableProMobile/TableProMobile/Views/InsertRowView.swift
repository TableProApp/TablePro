import SwiftUI
import TableProDatabase
import TableProModels

struct InsertRowView: View {
    let table: TableInfo
    let columnDetails: [ColumnInfo]
    let session: ConnectionSession?
    let databaseType: DatabaseType
    let safeModeLevel: SafeModeLevel
    var onInserted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// A column absent from this dictionary is left out of the `INSERT` so the database applies
    /// its own default. Keying by name rather than by position is what keeps the state from
    /// drifting when `columnDetails` arrives or changes while the sheet is open.
    @State private var fields: [String: PayloadValue] = [:]
    @State private var isSaving = false
    @State private var operationError: AppError?
    @State private var showOperationError = false
    @State private var showInsertConfirmation = false
    @State private var pendingInsertSQL: String?
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private var columnNames: [String] { columnDetails.map(\.name) }

    private var canSave: Bool {
        guard let driver = session?.driver else { return false }
        return buildInsertSQL(driver: driver) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(columnDetails, id: \.name) { column in
                    Section {
                        columnRow(column)
                    } header: {
                        header(for: column)
                    } footer: {
                        footer(for: column)
                    }
                }

                if !canSave {
                    Section {
                        Text("Fill in at least one column. This database cannot insert a row made only of defaults.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .formStyle(.grouped)
            .navigationTitle("Insert Row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save", isInProgress: isSaving) {
                        Task { await insertRow() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
            .onChange(of: columnNames) { _, newNames in
                let known = Set(newNames)
                fields = fields.filter { known.contains($0.key) }
            }
            .sensoryFeedback(.success, trigger: hapticSuccess)
            .sensoryFeedback(.error, trigger: hapticError)
            .alert(operationError?.title ?? "Error", isPresented: $showOperationError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let recovery = operationError?.recovery {
                    Text(verbatim: "\(operationError?.message ?? "") \(recovery)")
                } else {
                    Text(operationError?.message ?? "")
                }
            }
            .alert("Insert Row?", isPresented: $showInsertConfirmation) {
                Button(String(localized: "Insert"), role: .destructive) {
                    Task { await executePendingInsert() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "This will insert a row into %@. Continue?"), table.name))
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func columnRow(_ column: ColumnInfo) -> some View {
        HStack {
            if column.isGenerated {
                Text("Computed by the database")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                if fields[column.name] == .null {
                    Text("NULL")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    TextField(text: literalBinding(for: column), prompt: placeholder(for: column)) {
                        Text(verbatim: column.name)
                    }
                    .font(.body)
                    .keyboardType(keyboardType(for: column))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }

                Spacer()

                stateMenu(for: column)
            }
        }
    }

    private func stateMenu(for column: ColumnInfo) -> some View {
        Menu {
            Button {
                fields[column.name] = nil
            } label: {
                stateLabel(String(localized: "Use Default"), isActive: fields[column.name] == nil)
            }
            if column.isNullable {
                Button {
                    fields[column.name] = .null
                } label: {
                    stateLabel(String(localized: "NULL"), isActive: fields[column.name] == .null)
                }
            }
            Button {
                fields[column.name] = .text("")
            } label: {
                stateLabel(String(localized: "Empty String"), isActive: fields[column.name] == .text(""))
            }
        } label: {
            Text(stateBadge(for: column))
                .font(.caption2)
                .foregroundStyle(fields[column.name] == .null ? .white : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(fields[column.name] == .null ? Color.accentColor : Color(.systemFill))
                .clipShape(Capsule())
        }
        .accessibilityLabel(Text(String(format: String(localized: "Value for %@"), column.name)))
    }

    @ViewBuilder
    private func stateLabel(_ title: String, isActive: Bool) -> some View {
        if isActive {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func stateBadge(for column: ColumnInfo) -> String {
        switch fields[column.name] {
        case .none: return String(localized: "DEFAULT")
        case .some(.null): return String(localized: "NULL")
        case .some(.text): return String(localized: "VALUE")
        }
    }

    @ViewBuilder
    private func header(for column: ColumnInfo) -> some View {
        HStack(spacing: 6) {
            if column.isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text(column.name)

            Group {
                if column.isAutoIncrement {
                    Text("auto-increment")
                } else if column.isPrimaryKey {
                    Text("primary key")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            MetadataBadge(column.typeName)
        }
    }

    @ViewBuilder
    private func footer(for column: ColumnInfo) -> some View {
        if column.isGenerated {
            Text("This column is generated, so it is never written.")
                .font(.caption2)
        } else if let defaultValue = column.defaultValue {
            Text("Default: \(defaultValue)")
                .font(.caption2)
        }
    }

    // MARK: - Field State

    private func literalBinding(for column: ColumnInfo) -> Binding<String> {
        Binding<String>(
            get: {
                if case .text(let value) = fields[column.name] { return value }
                return ""
            },
            set: { newValue in
                fields[column.name] = newValue.isEmpty ? nil : .text(newValue)
            }
        )
    }

    private func placeholder(for column: ColumnInfo) -> Text {
        if column.isAutoIncrement { return Text("Auto") }
        if let defaultValue = column.defaultValue { return Text("Default: \(defaultValue)") }
        return Text("Default")
    }

    private func keyboardType(for column: ColumnInfo) -> UIKeyboardType {
        let type = column.typeName.uppercased()
        if type.contains("INT") || type.contains("REAL") || type.contains("FLOAT")
            || type.contains("DOUBLE") || type.contains("NUMERIC") || type.contains("DECIMAL")
        {
            return .decimalPad
        }
        return .default
    }

    // MARK: - Insert

    private func insertRow() async {
        guard let session else { return }

        guard let sql = buildInsertSQL(driver: session.driver) else { return }

        switch safeModeLevel.writePermission {
        case .blocked:
            return
        case .requiresConfirmation:
            pendingInsertSQL = sql
            showInsertConfirmation = true
        case .proceed:
            await executeInsert(sql: sql, session: session)
        }
    }

    private func executePendingInsert() async {
        guard let session, let sql = pendingInsertSQL else { return }
        pendingInsertSQL = nil
        await executeInsert(sql: sql, session: session)
    }

    private func buildInsertSQL(driver: any DatabaseDriver) -> String? {
        try? RowInsertPlanner.statements(
            table: table.name,
            schema: nil,
            type: databaseType,
            driver: driver,
            columns: columnDetails,
            rows: [PayloadRow(values: fields)],
            allowAllDefaults: true,
            dropsEmptyPrimaryKey: false
        ).first
    }

    private func executeInsert(sql: String, session: ConnectionSession) async {
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await session.driver.execute(query: sql)
            hapticSuccess.toggle()
            onInserted?()
            dismiss()
        } catch {
            let context = ErrorContext(operation: "insertRow", databaseType: databaseType)
            operationError = ErrorClassifier.classify(error, context: context)
            showOperationError = true
            hapticError.toggle()
        }
    }
}
