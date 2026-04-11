//
//  StructureView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct StructureView: View {
    let table: TableInfo
    let session: ConnectionSession?
    let databaseType: DatabaseType

    private static let logger = Logger(subsystem: "com.TablePro", category: "StructureView")

    enum Tab: String, CaseIterable {
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
    }

    @State private var selectedTab: Tab = .columns
    @State private var columns: [ColumnInfo] = []
    @State private var indexes: [IndexInfo] = []
    @State private var foreignKeys: [ForeignKeyInfo] = []
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
                    Text(tab.rawValue).tag(tab)
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

                        Text(column.typeName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
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
                                    Text("Primary")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }

                                if index.isUnique && !index.isPrimary {
                                    Text("Unique")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }

                                if !index.type.isEmpty {
                                    Text(index.type)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.fill.tertiary)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(index.columns.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    ForEach(foreignKeys, id: \.name) { fk in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fk.name)
                                .font(.body)
                                .fontWeight(.semibold)

                            Text(verbatim: "\(fk.column) \u{2192} \(fk.referencedTable).\(fk.referencedColumn)")
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
            async let fetchedColumns = session.driver.fetchColumns(table: table.name, schema: nil)
            async let fetchedIndexes = session.driver.fetchIndexes(table: table.name, schema: nil)
            async let fetchedForeignKeys = session.driver.fetchForeignKeys(table: table.name, schema: nil)

            self.columns = try await fetchedColumns
            self.indexes = try await fetchedIndexes
            self.foreignKeys = try await fetchedForeignKeys

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
}
