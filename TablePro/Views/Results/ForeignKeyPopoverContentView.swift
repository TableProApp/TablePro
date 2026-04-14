//
//  ForeignKeyPopoverContentView.swift
//  TablePro
//
//  SwiftUI popover content for searchable foreign key column editing.
//

import os
import SwiftUI
import TableProPluginKit

struct ForeignKeyPopoverContentView: View {
    let currentValue: String?
    let fkInfo: ForeignKeyInfo
    let connectionId: UUID
    let databaseType: DatabaseType
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var allValues: [FKValue] = []
    @State private var selectedId: String?
    @State private var isLoading = true

    private static let logger = Logger(subsystem: "com.TablePro", category: "FKPopover")
    private static let maxFetchRows = 1_000
    private static let rowHeight: CGFloat = 24
    private static let searchAreaHeight: CGFloat = 44
    private static let maxHeight: CGFloat = 320

    private var filteredValues: [FKValue] {
        let query = searchText.lowercased()
        if query.isEmpty { return allValues }
        return allValues.filter { $0.display.lowercased().contains(query) }
    }

    private var listHeight: CGFloat {
        let contentHeight = CGFloat(filteredValues.count) * Self.rowHeight
        return min(contentHeight, Self.maxHeight - Self.searchAreaHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 60)
            } else if filteredValues.isEmpty {
                Text("No values found")
                    .foregroundStyle(.secondary)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 60)
            } else {
                List(filteredValues, selection: $selectedId) { value in
                    rowLabel(for: value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onCommit(value.id)
                            onDismiss()
                        }
                        .listRowInsets(EdgeInsets(
                            top: 2, leading: 6, bottom: 2, trailing: 6
                        ))
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .frame(height: listHeight)
                .onKeyPress(.return) {
                    guard let id = selectedId else { return .ignored }
                    onCommit(id)
                    onDismiss()
                    return .handled
                }
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { await fetchForeignKeyValues() }
        .onChange(of: searchText) {
            selectedId = filteredValues.first?.id
        }
    }

    // MARK: - Row View

    @ViewBuilder
    private func rowLabel(for value: FKValue) -> some View {
        if value.id == currentValue {
            Text(value.display)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(value.display)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Data Fetching

    private func fetchForeignKeyValues() async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            Self.logger.error("No active driver for FK lookup")
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

        var displayColumn: String?
        do {
            let columnInfos = try await driver.fetchColumns(table: fkInfo.referencedTable, schema: fkInfo.referencedSchema)
            displayColumn = columnInfos.first(where: { col in
                col.name != fkInfo.referencedColumn &&
                !col.isPrimaryKey &&
                isTextLikeType(col.dataType)
            })?.name
        } catch {
            Self.logger.debug("Could not fetch columns for display: \(error.localizedDescription)")
        }

        let query: String
        let limitSuffix: String
        switch PluginManager.shared.paginationStyle(for: databaseType) {
        case .offsetFetch:
            limitSuffix = "OFFSET 0 ROWS FETCH NEXT \(Self.maxFetchRows) ROWS ONLY"
        case .limit:
            limitSuffix = "LIMIT \(Self.maxFetchRows)"
        }
        if let displayCol = displayColumn {
            let quotedDisplay = driver.quoteIdentifier(displayCol)
            query = "SELECT \(quotedColumn), \(quotedDisplay) FROM \(quotedTable) ORDER BY \(quotedColumn) \(limitSuffix)"
        } else {
            query = "SELECT DISTINCT \(quotedColumn) FROM \(quotedTable) ORDER BY \(quotedColumn) \(limitSuffix)"
        }

        do {
            let result = try await driver.execute(query: query)
            var values: [FKValue] = []
            for row in result.rows {
                guard !row.isEmpty, let idVal = row[0] else { continue }
                let displayVal: String
                if displayColumn != nil, row.count > 1, let second = row[1] {
                    displayVal = "\(idVal) — \(second)"
                } else {
                    displayVal = idVal
                }
                values.append(FKValue(id: idVal, display: displayVal))
            }
            allValues = values
            selectedId = currentValue
        } catch {
            Self.logger.error("FK value fetch failed: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Helpers

    private func isTextLikeType(_ typeString: String) -> Bool {
        let upper = typeString.uppercased()
        return upper.contains("CHAR") || upper.contains("TEXT") || upper.contains("NAME")
    }
}

// MARK: - FK Value Model

private struct FKValue: Identifiable, Hashable {
    let id: String
    let display: String
}
