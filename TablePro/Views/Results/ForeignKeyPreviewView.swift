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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .task { await fetchReferencedRow() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(fkInfo.column) → \(fkInfo.referencedTable).\(fkInfo.referencedColumn)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if let cellValue {
                Text(cellValue)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if cellValue == nil {
            Text("NULL — no referenced row")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(12)
        } else if values.isEmpty {
            Text("Referenced row not found")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 60)
        } else {
            rowList
        }
    }

    private var rowList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(zip(columns, values).enumerated()), id: \.offset) { index, pair in
                    let (col, value) = pair
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(col)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .lineLimit(1)
                            .layoutPriority(-1)

                        Text(valueText(value))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(value != nil ? .primary : .tertiary)
                            .italic(value == nil)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                }
            }
        }
        .frame(maxHeight: 300)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                onNavigate()
            } label: {
                Label(
                    String(format: String(localized: "Open %@"), fkInfo.referencedTable),
                    systemImage: "arrow.right"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(cellValue == nil || isLoading || values.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func valueText(_ value: String?) -> String {
        value ?? "NULL"
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

        let quotedTable = driver.quoteIdentifier(fkInfo.referencedTable)
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
