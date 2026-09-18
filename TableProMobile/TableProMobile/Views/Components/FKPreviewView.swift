import os
import SwiftUI
import TableProDatabase
import TableProModels

struct FKPreviewItem: Identifiable {
    let id = UUID()
    let fk: ForeignKeyInfo
    let value: String
}

struct FKPreviewView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "FKPreviewView")

    @Environment(\.dismiss) private var dismiss
    let fk: ForeignKeyInfo
    let value: String
    let session: ConnectionSession?
    let databaseType: DatabaseType

    @State private var columns: [ColumnInfo] = []
    @State private var row: [String?]?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let row {
                    List {
                        ForEach(Array(zip(columns, row).enumerated()), id: \.offset) { _, pair in
                            LabeledContent {
                                Text(verbatim: pair.1 ?? "NULL")
                                    .foregroundStyle(pair.1 == nil ? .secondary : .primary)
                                    .textSelection(.enabled)
                            } label: {
                                Text(pair.0.name)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Could Not Load the Referenced Row",
                        systemImage: "exclamationmark.triangle",
                        description: Text(verbatim: errorMessage)
                    )
                } else {
                    ContentUnavailableView(
                        "No Referenced Row",
                        systemImage: "arrow.right.circle",
                        description: Text("No row found in \(fk.referencedTable) where \(fk.referencedColumn) = '\(value)'")
                    )
                }
            }
            .navigationTitle(fk.referencedTable)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CloseButton { dismiss() }
                }
            }
            .task { await loadReferencedRow() }
        }
    }

    private func loadReferencedRow() async {
        guard let session else {
            isLoading = false
            return
        }

        do {
            let quoted = SQLBuilder.qualifiedIdentifier(
                table: fk.referencedTable, schema: fk.referencedSchema, for: databaseType
            )
            let quotedCol = SQLBuilder.quoteIdentifier(fk.referencedColumn, for: databaseType)
            let escapedValue = value.replacingOccurrences(of: "'", with: "''")
            /// SQL Server and Oracle reject `LIMIT`, so the clause comes from the shared builder
            /// rather than being written out here. Hardcoding it made every preview on those two
            /// engines fail, and the failure looked exactly like a key with no matching row.
            let pagination = SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: databaseType)
            let query = "SELECT * FROM \(quoted) WHERE \(quotedCol) = '\(escapedValue)' \(pagination)"
            let result = try await session.driver.execute(query: query)
            columns = result.columns
            row = result.rows.first
        } catch {
            Self.logger.warning("FK preview failed: \(error.localizedDescription, privacy: .public)")
            row = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
