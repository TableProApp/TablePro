import os
import SwiftUI
import TableProDatabase
import TableProModels

struct StructureView: View {
    let table: TableInfo
    let session: ConnectionSession?
    let databaseType: DatabaseType
    let schema: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "StructureView")

    enum Tab: String, CaseIterable {
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"

        var displayName: LocalizedStringResource {
            switch self {
            case .columns: LocalizedStringResource("Columns")
            case .indexes: LocalizedStringResource("Indexes")
            case .foreignKeys: LocalizedStringResource("Foreign Keys")
            }
        }
    }

    @State private var selectedTab: Tab = .columns
    @State private var columns: [ColumnInfo] = []
    @State private var indexes: [IndexInfo] = []
    @State private var foreignKeys: [ForeignKeyRow] = []
    @State private var isLoading = true
    @State private var appError: AppError?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading structure...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let appError {
                ErrorView(error: appError) {
                    await loadStructure()
                }
            } else {
                switch selectedTab {
                case .columns:
                    columnsTab
                case .indexes:
                    indexesTab
                case .foreignKeys:
                    foreignKeysTab
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Section", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadStructure() }
        .task { await loadStructure() }
    }

    // MARK: - Columns Tab

    private var columnsTab: some View {
        List {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(column.name)
                            .font(.body)
                            .fontWeight(.semibold)

                        Spacer()

                        MetadataBadge(column.typeName)
                    }

                    HStack(spacing: 8) {
                        if column.isPrimaryKey {
                            HStack(spacing: 3) {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("Primary Key")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if column.isNullable {
                            Text("Nullable")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let defaultValue = column.defaultValue {
                            Text("Default: \(defaultValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Indexes Tab

    private var indexesTab: some View {
        Group {
            if indexes.isEmpty {
                ContentUnavailableView(
                    "No Indexes",
                    systemImage: "list.number",
                    description: Text("This table has no indexes.")
                )
            } else {
                List {
                    ForEach(indexes, id: \.name) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(index.name)
                                    .font(.body)
                                    .fontWeight(.semibold)

                                Spacer()

                                if index.isPrimary {
                                    MetadataBadge(text: "Primary", foreground: .orange, background: Color.orange.opacity(0.15))
                                }

                                if index.isUnique && !index.isPrimary {
                                    MetadataBadge(text: "Unique", foreground: .blue, background: Color.blue.opacity(0.15))
                                }

                                if !index.type.isEmpty {
                                    MetadataBadge(index.type)
                                }
                            }

                            Text(index.columns.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !index.includedColumns.isEmpty {
                                Text(verbatim: "INCLUDE (\(index.includedColumns.joined(separator: ", ")))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let whereClause = index.whereClause, !whereClause.isEmpty {
                                Text(verbatim: "WHERE \(whereClause)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Foreign Keys Tab

    private var foreignKeysTab: some View {
        Group {
            if foreignKeys.isEmpty {
                ContentUnavailableView(
                    "No Foreign Keys",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This table has no foreign key relationships.")
                )
            } else {
                List {
                    ForEach(foreignKeys) { key in
                        let fk = key.pairs[0]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fk.name)
                                .font(.body)
                                .fontWeight(.semibold)

                            Text(verbatim: key.reference)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                if !fk.onDelete.isEmpty,
                                   fk.onDelete.uppercased() != "NO ACTION"
                                {
                                    Text("ON DELETE \(fk.onDelete)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                if !fk.onUpdate.isEmpty,
                                   fk.onUpdate.uppercased() != "NO ACTION"
                                {
                                    Text("ON UPDATE \(fk.onUpdate)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Data Loading

    private func loadStructure() async {
        guard let session else {
            appError = AppError(
                category: .config,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: String(localized: "Go back and reconnect to the database."),
                underlying: nil
            )
            isLoading = false
            return
        }

        isLoading = true
        appError = nil

        do {
            async let fetchedColumns = session.driver.fetchColumns(table: table.name, schema: schema)
            async let fetchedIndexes = session.driver.fetchIndexes(table: table.name, schema: schema)
            async let fetchedForeignKeys = session.driver.fetchForeignKeys(table: table.name, schema: schema)

            self.columns = try await fetchedColumns
            self.indexes = try await fetchedIndexes
            self.foreignKeys = ForeignKeyReference.keys(in: try await fetchedForeignKeys).map(ForeignKeyRow.init)

            Self.logger.debug("Loaded structure for \(table.name, privacy: .public): \(columns.count) columns, \(indexes.count) indexes, \(foreignKeys.count) foreign keys")
        } catch {
            let context = ErrorContext(
                operation: "loadStructure",
                databaseType: databaseType
            )
            appError = ErrorClassifier.classify(error, context: context)
        }

        isLoading = false
    }

    // Drivers report a composite key as one row per column pair, all under the key's name.
    nonisolated struct ForeignKeyRow: Identifiable {
        let pairs: [ForeignKeyInfo]

        var id: [String?] { [pairs[0].referencedSchema, pairs[0].referencedTable, pairs[0].name] }

        var reference: String {
            let first = pairs[0]
            guard pairs.count > 1 else {
                return "\(first.column) \u{2192} \(first.referencedTable).\(first.referencedColumn)"
            }
            let columns = pairs.map(\.column).joined(separator: ", ")
            let referenced = pairs.map(\.referencedColumn).joined(separator: ", ")
            return "\(columns) \u{2192} \(first.referencedTable) (\(referenced))"
        }
    }
}
