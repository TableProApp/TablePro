import AppKit
import SwiftUI

// One fixed column set: an `if` among table columns is macOS 14.4, so the Check column stays in every scope.
struct TableHealthFindingsTable: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

    var body: some View {
        Table(viewModel.rows, selection: $viewModel.selection, sortOrder: $viewModel.sortOrder) {
            TableColumn(TableHealthColumn.status.title, value: \TableHealthFindingRow.statusRank) { row in
                Text(verbatim: TableHealthColumn.status.text(for: row))
            }
            .width(min: 40, ideal: 52, max: 60)
            TableColumn(TableHealthColumn.check.title, value: \TableHealthFindingRow.checkOrder) { row in
                Text(verbatim: row.checkTitle)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150)
            TableColumn(
                TableHealthColumn.table.title,
                value: \TableHealthFindingRow.tableSortKey,
                comparator: String.StandardComparator.localizedStandard
            ) { row in
                Text(verbatim: row.tableSortKey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: 160)
            TableColumn(
                TableHealthColumn.object.title,
                value: \TableHealthFindingRow.objectSortKey,
                comparator: String.StandardComparator.localizedStandard
            ) { row in
                Text(verbatim: row.objectSortKey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 60, ideal: 140)
            TableColumn(TableHealthColumn.size.title, value: \TableHealthFindingRow.sizeSortKey) { row in
                Text(verbatim: TableHealthColumn.size.text(for: row))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 72, max: 110)
            TableColumn(
                TableHealthColumn.detail.title,
                value: \TableHealthFindingRow.detail,
                comparator: String.StandardComparator.localizedStandard
            ) { row in
                Text(verbatim: row.detail)
                    .lineLimit(1)
                    .help(row.detail)
            }
            .width(min: 120, ideal: 280)
        }
        .tableStyle(.inset)
        .alternatingRowBackgroundsCompat()
        .accessibilityLabel(String(localized: "Findings"))
        .contextMenu(forSelectionType: TableHealthFindingID.self) { ids in
            menu(for: viewModel.rows(for: ids))
        } primaryAction: { ids in
            if let finding = Self.singleTableFinding(in: viewModel.rows(for: ids)) {
                actions.openTable(finding)
            }
        }
        .onCopyCommand {
            TableHealthCopy.providers(viewModel.selectionTSV())
        }
    }

    // HIG, Context menus: unavailable items are left out, Copy aside.
    @ViewBuilder
    private func menu(for rows: [TableHealthFindingRow]) -> some View {
        if !rows.isEmpty {
            let findings = rows.compactMap(\.finding)
            let fixCount = findings.filter(TableHealthViewModel.hasFix).count
            if let finding = Self.singleTableFinding(in: rows) {
                Button(String(localized: "Open Table")) { actions.openTable(finding) }
            }
            if fixCount > 0 {
                Button(fixCount == 1 ? String(localized: "Open Fix in Editor") : String(localized: "Open Fixes in Editor")) {
                    if let text = viewModel.fixText(for: findings, databaseType: databaseType) {
                        actions.openInEditor(text)
                    }
                }
            }
            Divider()
            Button(String(localized: "Copy")) {
                if let text = viewModel.tsv(for: rows) {
                    ClipboardService.shared.writeText(text)
                }
            }
            if fixCount > 0 {
                Button(String(localized: "Copy Fix SQL")) {
                    if let text = viewModel.fixText(for: findings, databaseType: databaseType) {
                        ClipboardService.shared.writeText(text)
                    }
                }
            }
            Divider()
            let ids = Set(rows.map(\.id))
            if rows.allSatisfy({ $0.status == .ignored }) {
                Button(String(localized: "Stop Ignoring")) { viewModel.setIgnored(ids, ignored: false) }
            } else {
                Button(String(localized: "Ignore")) { viewModel.setIgnored(ids, ignored: true) }
            }
            if fixCount > 0 {
                Button(String(localized: "Save Fix Script…")) {
                    if let script = viewModel.fixScript(for: findings, databaseType: databaseType) {
                        actions.saveFixScript(script)
                    }
                }
            }
        }
    }

    // Open Table applies when the rows name one table, however many findings it has.
    static func singleTableFinding(in rows: [TableHealthFindingRow]) -> TableHealthFinding? {
        let findings = rows.compactMap(\.finding).filter { $0.table != nil }
        guard let first = findings.first,
              findings.allSatisfy({ $0.schema == first.schema && $0.table == first.table })
        else { return nil }
        return first
    }
}

struct TableHealthResolvedTable: View {
    @ObservedObject var viewModel: TableHealthViewModel

    var body: some View {
        Table(viewModel.rows, selection: $viewModel.selection, sortOrder: $viewModel.resolvedSortOrder) {
            TableColumn(TableHealthColumn.check.title, value: \TableHealthFindingRow.checkOrder) { row in
                Text(verbatim: row.checkTitle)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150)
            TableColumn(
                TableHealthColumn.table.title,
                value: \TableHealthFindingRow.tableSortKey,
                comparator: String.StandardComparator.localizedStandard
            ) { row in
                Text(verbatim: row.tableSortKey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: 180)
            TableColumn(
                TableHealthColumn.object.title,
                value: \TableHealthFindingRow.objectSortKey,
                comparator: String.StandardComparator.localizedStandard
            ) { row in
                Text(verbatim: row.objectSortKey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 60, ideal: 160)
            TableColumn(TableHealthColumn.lastSeen.title, value: \TableHealthFindingRow.lastSeenSortKey) { row in
                Text(verbatim: TableHealthColumn.lastSeen.text(for: row))
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 160)
        }
        .tableStyle(.inset)
        .alternatingRowBackgroundsCompat()
        .accessibilityLabel(String(localized: "Resolved Findings"))
        .contextMenu(forSelectionType: TableHealthFindingID.self) { ids in
            let rows = viewModel.rows(for: ids)
            if !rows.isEmpty {
                Button(String(localized: "Copy")) {
                    if let text = viewModel.tsv(for: rows) {
                        ClipboardService.shared.writeText(text)
                    }
                }
                Divider()
            }
            Button(String(localized: "Clear Resolved")) { viewModel.clearResolved() }
        }
        .onCopyCommand {
            TableHealthCopy.providers(viewModel.selectionTSV())
        }
    }
}

enum TableHealthCopy {
    static func providers(_ text: String?) -> [NSItemProvider] {
        guard let text else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }
}
