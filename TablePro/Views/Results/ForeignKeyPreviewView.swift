//
//  ForeignKeyPreviewView.swift
//  TablePro
//
//  Read-only popover showing the referenced row for a foreign key cell.
//

import os
import SwiftUI
import TableProPluginKit

struct ForeignKeyPreviewView: View {
    let cellValue: String?
    let fkInfo: ForeignKeyInfo
    let connectionId: UUID
    let databaseType: DatabaseType
    let onNavigate: () -> Void
    let onDismiss: () -> Void

    @State private var columns: [String] = []
    @State private var values: [String?] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "FKPreview")

    private var referencedTableDisplay: String {
        if let schema = fkInfo.referencedSchema {
            return "\(schema).\(fkInfo.referencedTable)"
        }
        return fkInfo.referencedTable
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .task { await fetchReferencedRow() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("\(fkInfo.column) → \(referencedTableDisplay).\(fkInfo.referencedColumn)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if cellValue == nil {
            Text("NULL — no referenced row")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(Color(nsColor: .systemRed))
                .font(.callout)
                .padding(10)
        } else if values.isEmpty {
            Text("Referenced row not found")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(zip(columns, values).enumerated()), id: \.offset) { _, pair in
                        let (col, value) = pair
                        HStack(alignment: .top, spacing: 8) {
                            Text(col)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .trailing)
                                .lineLimit(1)

                            if let val = value {
                                Text(val)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            } else {
                                Text("NULL")
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .italic()
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                onNavigate()
            } label: {
                Label(
                    String(format: String(localized: "Open %@"), referencedTableDisplay),
                    systemImage: "arrow.right"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(cellValue == nil || isLoading || values.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Data Fetching

    private func fetchReferencedRow() async {
        guard let value = cellValue else {
            isLoading = false
            return
        }

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            Self.logger.error("No active driver for FK preview")
            errorMessage = String(localized: "No database connection")
            isLoading = false
            return
        }

        let quotedTable: String
        if let schema = fkInfo.referencedSchema {
            quotedTable = "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(fkInfo.referencedTable))"
        } else {
            quotedTable = driver.quoteIdentifier(fkInfo.referencedTable)
        }
        let quotedColumn = driver.quoteIdentifier(fkInfo.referencedColumn)
        let escapedValue = driver.escapeStringLiteral(value)

        let limitClause: String
        switch PluginManager.shared.paginationStyle(for: databaseType) {
        case .offsetFetch:
            limitClause = "OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"
        case .limit:
            limitClause = "LIMIT 1"
        }

        let query = "SELECT * FROM \(quotedTable) WHERE \(quotedColumn) = '\(escapedValue)' \(limitClause)"

        do {
            let result = try await driver.execute(query: query)
            if let firstRow = result.rows.first {
                columns = result.columns
                values = firstRow
            }
        } catch {
            Self.logger.error("FK preview query failed: \(error.localizedDescription)")
            errorMessage = String(localized: "Failed to load referenced row")
        }

        isLoading = false
    }
}
