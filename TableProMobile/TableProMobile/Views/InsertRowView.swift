//
//  InsertRowView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct InsertRowView: View {
    let table: TableInfo
    let columnDetails: [ColumnInfo]
    let session: ConnectionSession?
    let databaseType: DatabaseType
    var onInserted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String]
    @State private var isNullFlags: [Bool]

    init(
        table: TableInfo,
        columnDetails: [ColumnInfo],
        session: ConnectionSession?,
        databaseType: DatabaseType,
        onInserted: (() -> Void)? = nil
    ) {
        self.table = table
        self.columnDetails = columnDetails
        self.session = session
        self.databaseType = databaseType
        self.onInserted = onInserted
        _values = State(initialValue: Array(repeating: "", count: columnDetails.count))
        _isNullFlags = State(initialValue: columnDetails.map { col in
            col.isPrimaryKey && col.typeName.uppercased().contains("INT")
        })
    }
    @State private var isSaving = false
    @State private var operationError: AppError?
    @State private var showOperationError = false
    @State private var hapticSuccess = false
    @State private var hapticError = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(columnDetails.enumerated()), id: \.offset) { index, column in
                    Section {
                        HStack {
                            if isNullFlags[safe: index] == true {
                                Text("NULL")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            } else {
                                TextField(placeholder(for: column), text: binding(for: index))
                                    .font(.body)
                                    .keyboardType(keyboardType(for: column))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }

                            Spacer()

                            Button {
                                guard index < isNullFlags.count else { return }
                                isNullFlags[index].toggle()
                                if isNullFlags[index], index < values.count {
                                    values[index] = ""
                                }
                            } label: {
                                Text("NULL")
                                    .font(.caption2)
                                    .foregroundStyle(isNullFlags[safe: index] == true ? .white : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isNullFlags[safe: index] == true ? Color.accentColor : Color(.systemFill))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            if column.isPrimaryKey {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Text(column.name)

                            if column.isPrimaryKey {
                                Text(isAutoIncrement(column) ? "auto-increment" : "primary key")
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
                    } footer: {
                        if let defaultValue = column.defaultValue {
                            Text("Default: \(defaultValue)")
                                .font(.caption2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Insert Row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await insertRow() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving)
                }
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
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding<String>(
            get: { values[safe: index] ?? "" },
            set: { newValue in
                guard index < values.count else { return }
                values[index] = newValue
            }
        )
    }

    private func placeholder(for column: ColumnInfo) -> String {
        if column.isPrimaryKey { return "Auto" }
        if let defaultValue = column.defaultValue { return "Default: \(defaultValue)" }
        return column.typeName
    }

    private func isAutoIncrement(_ column: ColumnInfo) -> Bool {
        column.isPrimaryKey && column.typeName.uppercased().contains("INT")
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

    private func insertRow() async {
        guard let session else { return }

        isSaving = true
        defer { isSaving = false }

        var insertColumns: [String] = []
        var insertValues: [String?] = []

        for (index, column) in columnDetails.enumerated() {
            let isNull = isNullFlags[safe: index] == true
            let text = values[safe: index] ?? ""

            if column.isPrimaryKey && (isNull || text.isEmpty) {
                continue
            }

            insertColumns.append(column.name)
            if isNull {
                insertValues.append(nil)
            } else {
                insertValues.append(text)
            }
        }

        let sql = SQLBuilder.buildInsert(
            table: table.name,
            type: databaseType,
            columns: insertColumns,
            values: insertValues
        )

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
