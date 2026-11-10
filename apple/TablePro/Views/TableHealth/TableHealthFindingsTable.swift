import AppKit
import SwiftUI

struct TableHealthFindingsTable: View {
    static let columns: [TableHealthTableColumn] = [
        TableHealthTableColumn(.status, min: 40, ideal: 52, max: 60),
        TableHealthTableColumn(.check, min: 80, ideal: 150),
        TableHealthTableColumn(.table, min: 80, ideal: 160),
        TableHealthTableColumn(.object, min: 60, ideal: 140),
        TableHealthTableColumn(.size, min: 50, ideal: 72, max: 110),
        TableHealthTableColumn(.detail, min: 120, ideal: 280),
    ]

    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

    var body: some View {
        TableHealthRowsTable(
            rows: viewModel.rows,
            columns: Self.columns,
            selection: $viewModel.selection,
            sortOrder: $viewModel.sortOrder,
            accessibilityLabel: String(localized: "Findings"),
            menu: TableHealthRowMenu.findings,
            perform: { command, rows in perform(command, on: rows) },
            primaryAction: { rows in
                if let finding = TableHealthRowMenu.singleTableFinding(in: rows) {
                    actions.openTable(finding)
                }
            },
            copyText: { viewModel.selectionTSV() }
        )
    }

    private func perform(_ command: TableHealthRowCommand, on rows: [TableHealthFindingRow]) {
        let findings = rows.compactMap(\.finding)
        switch command {
        case .openTable:
            if let finding = TableHealthRowMenu.singleTableFinding(in: rows) {
                actions.openTable(finding)
            }
        case .openFixes:
            if let text = viewModel.fixText(for: findings, databaseType: databaseType) {
                actions.openInEditor(text)
            }
        case .copy:
            if let text = viewModel.tsv(for: rows) {
                ClipboardService.shared.writeText(text)
            }
        case .copyFixSQL:
            if let text = viewModel.fixText(for: findings, databaseType: databaseType) {
                ClipboardService.shared.writeText(text)
            }
        case .ignore:
            viewModel.setIgnored(Set(rows.map(\.id)), ignored: true)
        case .stopIgnoring:
            viewModel.setIgnored(Set(rows.map(\.id)), ignored: false)
        case .saveFixScript:
            if let script = viewModel.fixScript(for: findings, databaseType: databaseType) {
                actions.saveFixScript(script)
            }
        case .clearResolved:
            viewModel.clearResolved()
        }
    }
}

struct TableHealthResolvedTable: View {
    static let columns: [TableHealthTableColumn] = [
        TableHealthTableColumn(.check, min: 80, ideal: 150),
        TableHealthTableColumn(.table, min: 80, ideal: 180),
        TableHealthTableColumn(.object, min: 60, ideal: 160),
        TableHealthTableColumn(.lastSeen, min: 100, ideal: 160),
    ]

    @ObservedObject var viewModel: TableHealthViewModel

    var body: some View {
        TableHealthRowsTable(
            rows: viewModel.rows,
            columns: Self.columns,
            selection: $viewModel.selection,
            sortOrder: $viewModel.resolvedSortOrder,
            accessibilityLabel: String(localized: "Resolved Findings"),
            menu: TableHealthRowMenu.resolved,
            perform: { command, rows in
                switch command {
                case .copy:
                    if let text = viewModel.tsv(for: rows) {
                        ClipboardService.shared.writeText(text)
                    }
                case .clearResolved:
                    viewModel.clearResolved()
                case .openTable, .openFixes, .copyFixSQL, .ignore, .stopIgnoring, .saveFixScript:
                    break
                }
            },
            copyText: { viewModel.selectionTSV() }
        )
    }
}

enum TableHealthRowCommand: Equatable, SidebarMenuShortcutProviding {
    case openTable
    case openFixes
    case copy
    case copyFixSQL
    case ignore
    case stopIgnoring
    case saveFixScript
    case clearResolved

    var shortcutAction: ShortcutAction? { nil }
}

// HIG, Context menus: unavailable items are left out, Copy aside.
enum TableHealthRowMenu {
    static func findings(_ rows: [TableHealthFindingRow]) -> [SidebarMenuSection<TableHealthRowCommand>] {
        guard !rows.isEmpty else { return [] }
        let fixCount = rows.compactMap(\.finding).filter(TableHealthViewModel.hasFix).count

        var open: [SidebarMenuItem<TableHealthRowCommand>] = []
        if singleTableFinding(in: rows) != nil {
            open.append(.command(String(localized: "Open Table"), .openTable))
        }
        if fixCount > 0 {
            let title = fixCount == 1 ? String(localized: "Open Fix in Editor") : String(localized: "Open Fixes in Editor")
            open.append(.command(title, .openFixes))
        }

        var copy: [SidebarMenuItem<TableHealthRowCommand>] = [.command(String(localized: "Copy"), .copy)]
        if fixCount > 0 {
            copy.append(.command(String(localized: "Copy Fix SQL"), .copyFixSQL))
        }

        var manage: [SidebarMenuItem<TableHealthRowCommand>] = []
        if rows.allSatisfy({ $0.status == .ignored }) {
            manage.append(.command(String(localized: "Stop Ignoring"), .stopIgnoring))
        } else {
            manage.append(.command(String(localized: "Ignore"), .ignore))
        }
        if fixCount > 0 {
            manage.append(.command(String(localized: "Save Fix Script…"), .saveFixScript))
        }
        return [SidebarMenuSection(open), SidebarMenuSection(copy), SidebarMenuSection(manage)]
    }

    static func resolved(_ rows: [TableHealthFindingRow]) -> [SidebarMenuSection<TableHealthRowCommand>] {
        let copy: [SidebarMenuItem<TableHealthRowCommand>] = rows.isEmpty
            ? []
            : [.command(String(localized: "Copy"), .copy)]
        return [SidebarMenuSection(copy), SidebarMenuSection([.command(String(localized: "Clear Resolved"), .clearResolved)])]
    }

    static func checks(scope: TableHealthScope?, resolvedCount: Int) -> [SidebarMenuSection<TableHealthRowCommand>] {
        guard scope == .resolved, resolvedCount > 0 else { return [] }
        return [SidebarMenuSection([.command(String(localized: "Clear Resolved"), .clearResolved)])]
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
