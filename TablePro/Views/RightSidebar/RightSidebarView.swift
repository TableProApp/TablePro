//
//  RightSidebarView.swift
//  TablePro
//
//  Professional macOS inspector-style right sidebar.
//

import SwiftUI

/// Right sidebar that shows table metadata or selected row details
struct RightSidebarView: View {
    let tableName: String?
    let tableMetadata: TableMetadata?
    let selectedRowData: [(column: String, value: String?, type: String)]?
    let isEditable: Bool
    let isRowDeleted: Bool
    let onSave: () -> Void

    var editState: MultiRowEditState
    let databaseType: DatabaseType

    @State private var searchText: String = ""

    // MARK: - Inspector Mode

    private enum InspectorMode {
        case editRow, rowDetails, tableInfo, empty
    }

    private var contentMode: InspectorMode {
        if selectedRowData != nil {
            return isEditable && !isRowDeleted ? .editRow : .rowDetails
        }
        if tableMetadata != nil { return .tableInfo }
        return .empty
    }

    var body: some View {
        switch contentMode {
        case .editRow, .rowDetails:
            if let rowData = selectedRowData {
                rowDetailForm(rowData)
            }
        case .tableInfo:
            if let metadata = tableMetadata {
                tableInfoContent(metadata)
            }
        case .empty:
            emptyState
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "No Selection"),
            systemImage: "sidebar.right",
            description: Text(String(localized: "Select a row or table to view details"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table Info Content

    private func tableInfoContent(_ metadata: TableMetadata) -> some View {
        Form {
            Section {
                LabeledContent(
                    String(localized: "Data Size"),
                    value: TableMetadata.formatSize(metadata.dataSize))
                LabeledContent(
                    String(localized: "Index Size"),
                    value: TableMetadata.formatSize(metadata.indexSize))
                LabeledContent(
                    String(localized: "Total Size"),
                    value: TableMetadata.formatSize(metadata.totalSize))
            } header: {
                Text("SIZE")
            }

            Section {
                if let rows = metadata.rowCount {
                    LabeledContent(String(localized: "Rows"), value: "\(rows)")
                }
                if let avgLen = metadata.avgRowLength {
                    LabeledContent(String(localized: "Avg Row"), value: "\(avgLen) B")
                }
            } header: {
                Text("STATISTICS")
            }

            if metadata.engine != nil || metadata.collation != nil {
                Section {
                    if let engine = metadata.engine {
                        LabeledContent(String(localized: "Engine"), value: engine)
                    }
                    if let collation = metadata.collation {
                        LabeledContent(String(localized: "Collation"), value: collation)
                            .help(collation)
                    }
                } header: {
                    Text("METADATA")
                }
            }

            if metadata.createTime != nil || metadata.updateTime != nil {
                Section {
                    if let create = metadata.createTime {
                        LabeledContent(String(localized: "Created"), value: formatDate(create))
                    }
                    if let update = metadata.updateTime {
                        LabeledContent(String(localized: "Updated"), value: formatDate(update))
                    }
                } header: {
                    Text("TIMESTAMPS")
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        RightSidebarView.dateFormatter.string(from: date)
    }

    // MARK: - Row Detail Form

    private func rowDetailForm(
        _ rowData: [(column: String, value: String?, type: String)]
    ) -> some View {
        let filtered =
            searchText.isEmpty
            ? editState.fields
            : editState.fields.filter {
                $0.columnName.localizedCaseInsensitiveContains(searchText)
                    || ($0.originalValue?.localizedCaseInsensitiveContains(searchText) ?? false)
            }

        return VStack(spacing: 0) {
            // Inline search field
            SearchFieldView(
                placeholder: "Search for field...",
                text: $searchText,
                fontSize: 11
            )
            .padding(.horizontal, 10)

            Divider()

            List {
                Section {
                    if filtered.isEmpty && !searchText.isEmpty {
                        Text("No matching fields")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filtered, id: \.id) { field in
                            fieldDetailRow(field, at: field.columnIndex, isEditable: contentMode == .editRow)
                        }
                    }
                } header: {
                    HStack {
                        Text("FIELDS")
                        Spacer()
                        Text("\(filtered.count)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 15)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if contentMode == .editRow && editState.hasEdits {
                Divider()
                Button(action: onSave) {
                    Text("Save Changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func fieldDetailRow(_ field: FieldEditState, at index: Int, isEditable: Bool) -> some View {
        FieldDetailView(
            context: FieldEditorContext(
                columnName: field.columnName,
                columnType: field.columnTypeEnum,
                isLongText: field.isLongText,
                value: isEditable ? Binding(
                    get: { field.pendingValue ?? field.originalValue ?? "" },
                    set: { editState.updateField(at: index, value: $0) }
                ) : .constant(field.originalValue ?? ""),
                originalValue: field.originalValue,
                hasMultipleValues: field.hasMultipleValues,
                isReadOnly: !isEditable
            ),
            isPendingNull: field.isPendingNull,
            isPendingDefault: field.isPendingDefault,
            isModified: field.hasEdit,
            isTruncated: field.isTruncated,
            isLoadingFullValue: field.isLoadingFullValue,
            databaseType: databaseType,
            onSetNull: { editState.setFieldToNull(at: index) },
            onSetDefault: { editState.setFieldToDefault(at: index) },
            onSetEmpty: { editState.setFieldToEmpty(at: index) },
            onSetFunction: { editState.setFieldToFunction(at: index, function: $0) }
        )
    }
}

// MARK: - Preview

struct RightSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        RightSidebarView(
            tableName: "users",
            tableMetadata: TableMetadata(
                tableName: "users",
                dataSize: 16_384,
                indexSize: 8_192,
                totalSize: 24_576,
                avgRowLength: 128,
                rowCount: 1_250,
                comment: "User accounts",
                engine: "InnoDB",
                collation: "utf8mb4_unicode_ci",
                createTime: Date(),
                updateTime: nil
            ),
            selectedRowData: nil,
            isEditable: false,
            isRowDeleted: false,
            onSave: {},
            editState: MultiRowEditState(),
            databaseType: .mysql
        )
        .frame(width: 280, height: 400)
    }
}
