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
                    Button("Done") { dismiss() }
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
            let quoted = SQLBuilder.quoteIdentifier(fk.referencedTable, for: databaseType)
            let quotedCol = SQLBuilder.quoteIdentifier(fk.referencedColumn, for: databaseType)
            let escapedValue = value.replacingOccurrences(of: "'", with: "''")
            let query = "SELECT * FROM \(quoted) WHERE \(quotedCol) = '\(escapedValue)' LIMIT 1"
            let result = try await session.driver.execute(query: query)
            columns = result.columns
            row = result.rows.first
        } catch {
            Self.logger.warning("FK preview failed: \(error.localizedDescription, privacy: .public)")
            row = nil
        }
        isLoading = false
    }
}
