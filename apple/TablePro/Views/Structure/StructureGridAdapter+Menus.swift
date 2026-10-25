//
//  StructureGridAdapter+Menus.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension StructureGridAdapter {
    // The grid adds Copy, Duplicate, Delete and Undo Delete from its commands; these are the schema's own.
    func structureRowMenuItems(for rowIDs: [RowID]) -> [NSMenuItem] {
        guard showsGrid, !rowIDs.isEmpty else { return [] }
        let indices = sourceIndices(of: rowIDs)
        let tab = selectedTab
        guard !indices.contains(where: { structureChangeManager.deleteInsertState(for: $0, tab: tab).isDeleted }) else {
            return []
        }

        var items = [
            menuItem(String(localized: "Copy Name")) { [weak self] in self?.copyNames(indices) },
            menuItem(String(localized: "Copy Definition")) { [weak self] in self?.copyDefinitions(indices) },
            copyAsItem(indices),
        ]

        let single = indices.count == 1 ? indices.first : nil
        if tab == .foreignKeys, let single, structureChangeManager.workingForeignKeys.indices.contains(single) {
            let referenced = structureChangeManager.workingForeignKeys[single].referencedTable
            if !referenced.isEmpty {
                items.append(.separator())
                items.append(menuItem(String(format: String(localized: "Open %@"), referenced)) { [weak self] in
                    self?.navigateToForeignKey(sourceIndex: single)
                })
            }
        }

        let moves = columnMoveItems(movingRow: single)
        if !moves.isEmpty {
            items.append(.separator())
            items.append(contentsOf: moves)
        }
        return items
    }

    // Moving by menu gives the keyboard and VoiceOver the reorder a drag gives the pointer.
    private func columnMoveItems(movingRow row: Int?) -> [NSMenuItem] {
        guard selectedTab == .columns else { return [] }
        let reorder = model.configuration.rowReorder
        guard reorder.isEnabled || reorder.unavailableReason != nil else { return [] }
        let count = structureChangeManager.workingColumns.count
        var items = [
            columnMoveItem(String(localized: "Move Column Up"), row: row, .up, count: count, isEnabled: reorder.isEnabled),
            columnMoveItem(String(localized: "Move Column Down"), row: row, .down, count: count, isEnabled: reorder.isEnabled),
        ]
        guard let reason = reorder.unavailableReason else { return items }
        let explanation = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        items.append(explanation)
        return items
    }

    private func columnMoveItem(
        _ title: String,
        row: Int?,
        _ direction: ColumnMove.Direction,
        count: Int,
        isEnabled: Bool
    ) -> NSMenuItem {
        guard isEnabled, let row, ColumnMove.isPossible(movingRow: row, direction, columnCount: count) else {
            return NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        return menuItem(title) { [weak self] in
            self?.moveRowHandler?(row, ColumnMove.dropIndex(movingRow: row, direction))
        }
    }

    private func copyAsItem(_ indices: [Int]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(menuItem("CSV") { [weak self] in self?.copyAsCSV(indices) })
        submenu.addItem(menuItem("JSON") { [weak self] in self?.copyAsJSON(indices) })
        submenu.addItem(menuItem("SQL") { [weak self] in self?.copyDefinitions(indices) })
        let item = NSMenuItem(title: String(localized: "Copy As"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    func makeEmptySpaceMenu() -> NSMenu? {
        guard showsGrid, editGate.canEditSchema else { return nil }
        let label: String
        switch selectedTab {
        case .columns:
            guard editGate.allows(.addColumn) else { return nil }
            label = String(localized: "Add Column")
        case .indexes:
            guard editGate.allows(.addIndex) else { return nil }
            label = String(localized: "Add Index")
        case .foreignKeys:
            guard canEditForeignKeys else { return nil }
            label = String(localized: "Add Foreign Key")
        case .checkConstraints:
            guard editGate.allows(.addCheckConstraint) else { return nil }
            label = String(localized: "Add Check Constraint")
        case .ddl, .parts, .triggers:
            return nil
        }
        let menu = NSMenu()
        menu.addItem(menuItem(label) { [weak self] in self?.addRow() })
        return menu
    }

    private func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = StructureMenuTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(StructureMenuTarget.runAction), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }

    // MARK: - Copy

    private func unsortedProvider(includingPrimaryKey: Bool) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: structureChangeManager,
            tab: selectedTab,
            databaseType: connection.type,
            additionalFields: includingPrimaryKey ? [.primaryKey] : [],
            serverSupport: session?.serverSupport ?? .unrestricted
        )
    }

    func copyNames(_ indices: [Int]) {
        let provider = unsortedProvider(includingPrimaryKey: false)
        let names = indices.sorted().compactMap { provider.row(at: $0)?.first ?? nil }
        guard !names.isEmpty else { return }
        ClipboardService.shared.writeText(names.joined(separator: "\n"))
    }

    func copyDefinitions(_ indices: [Int]) {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
        var definitions: [String] = []
        for index in indices.sorted() {
            switch selectedTab {
            case .columns:
                guard structureChangeManager.workingColumns.indices.contains(index),
                      let sql = driver.generateColumnDefinitionSQL(column: structureChangeManager.workingColumns[index].toPlugin())
                else { continue }
                definitions.append(sql)
            case .indexes:
                guard structureChangeManager.workingIndexes.indices.contains(index),
                      let sql = driver.generateIndexDefinitionSQL(
                          index: structureChangeManager.workingIndexes[index].toPlugin(), tableName: tableName
                      )
                else { continue }
                definitions.append(sql)
            case .foreignKeys:
                guard structureChangeManager.workingForeignKeys.indices.contains(index),
                      let sql = driver.generateForeignKeyDefinitionSQL(fk: structureChangeManager.workingForeignKeys[index].toPlugin())
                else { continue }
                definitions.append(sql)
            case .checkConstraints:
                guard structureChangeManager.workingCheckConstraints.indices.contains(index) else { continue }
                let constraint = structureChangeManager.workingCheckConstraints[index]
                definitions.append("CONSTRAINT \(driver.quoteIdentifier(constraint.name)) CHECK (\(constraint.expression))")
            case .ddl, .parts, .triggers:
                break
            }
        }
        guard !definitions.isEmpty else { return }
        ClipboardService.shared.writeText(definitions.joined(separator: "\n"))
    }

    func copyAsCSV(_ indices: [Int]) {
        let provider = unsortedProvider(includingPrimaryKey: true)
        let headers = provider.columns
        guard !headers.isEmpty else { return }
        var lines = [headers.map(CsvRowConverter.encode).joined(separator: ",")]
        for index in indices.sorted() {
            guard let row = provider.row(at: index) else { continue }
            lines.append(row.map { CsvRowConverter.encode($0 ?? "") }.joined(separator: ","))
        }
        ClipboardService.shared.writeText(lines.joined(separator: "\n"))
    }

    func copyAsJSON(_ indices: [Int]) {
        let provider = unsortedProvider(includingPrimaryKey: true)
        let headers = provider.columns
        guard !headers.isEmpty else { return }
        var objects: [[String: String]] = []
        for index in indices.sorted() {
            guard let row = provider.row(at: index) else { continue }
            var object: [String: String] = [:]
            for (position, header) in headers.enumerated() where position < row.count {
                object[header] = row[position] ?? ""
            }
            objects.append(object)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        ClipboardService.shared.writeText(json)
    }

    // The grid's own Copy reaches the definitions too, so a paste in this tab stages them again.
    func gridCopyRows(_ rowIDs: [RowID]) -> Bool {
        guard showsGrid, !rowIDs.isEmpty else { return false }
        copyRows(rowIDs)
        return true
    }

    // The definitions ride on the structure pasteboard type, so Paste can stage them again.
    func copyRows(_ rowIDs: [RowID]) {
        guard showsGrid, !rowIDs.isEmpty else { return }
        let ordered = rowIDs.sorted { (model.displayIndex(of: $0) ?? .max) < (model.displayIndex(of: $1) ?? .max) }
        let indices = sourceIndices(of: ordered)
        let manager = structureChangeManager
        let encoder = JSONEncoder()
        let encoded: Data?
        switch selectedTab {
        case .columns:
            encoded = try? encoder.encode(indices.sorted().compactMap { manager.workingColumns.indices.contains($0) ? manager.workingColumns[$0] : nil })
        case .indexes:
            encoded = try? encoder.encode(indices.sorted().compactMap { manager.workingIndexes.indices.contains($0) ? manager.workingIndexes[$0] : nil })
        case .foreignKeys:
            encoded = try? encoder.encode(indices.sorted().compactMap {
                manager.workingForeignKeys.indices.contains($0) ? manager.workingForeignKeys[$0] : nil
            })
        case .checkConstraints:
            encoded = try? encoder.encode(indices.sorted().compactMap {
                manager.workingCheckConstraints.indices.contains($0) ? manager.workingCheckConstraints[$0] : nil
            })
        case .ddl, .parts, .triggers:
            encoded = nil
        }

        let rows = model.rows
        let lines = ordered.compactMap { rowID -> String? in
            rows.row(withID: rowID)?.values.map { $0.asText ?? "NULL" }.joined(separator: "\t")
        }

        let item = NSPasteboardItem()
        if let encoded, let json = String(data: encoded, encoding: .utf8) {
            item.setString(json, forType: TableStructureView.structurePasteboardType)
            item.setString(connection.type.rawValue, forType: TableStructureView.structureSourceTypePasteboardType)
        }
        if !lines.isEmpty {
            item.setString(lines.joined(separator: "\n"), forType: .string)
        }
        guard !item.types.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func pasteRows() {
        guard canStageAddForSelectedTab,
              let data = NSPasteboard.general.data(forType: TableStructureView.structurePasteboardType) else { return }
        let decoder = JSONDecoder()
        let manager = structureChangeManager
        switch selectedTab {
        case .columns:
            guard let columns = try? decoder.decode([EditableColumnDefinition].self, from: data) else { return }
            for column in columns {
                manager.addColumn(column.withNewIdentity())
            }
        case .indexes:
            guard let indexes = try? decoder.decode([EditableIndexDefinition].self, from: data) else { return }
            let source = NSPasteboard.general
                .string(forType: TableStructureView.structureSourceTypePasteboardType)
                .map(DatabaseType.init(rawValue:))
            for index in indexes {
                manager.addIndex(index.pasted(from: source, into: connection.type))
            }
        case .foreignKeys:
            guard let foreignKeys = try? decoder.decode([EditableForeignKeyDefinition].self, from: data) else { return }
            for foreignKey in foreignKeys {
                manager.addForeignKey(foreignKey.withNewIdentity())
            }
        case .checkConstraints:
            guard let constraints = try? decoder.decode([EditableCheckConstraintDefinition].self, from: data) else { return }
            for constraint in constraints {
                manager.addCheckConstraint(constraint.withNewIdentity())
            }
        case .ddl, .parts, .triggers:
            return
        }
        refresh()
    }
}

// Held by the item's `representedObject`, so it outlives the menu that shows it.
final class StructureMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func runAction() {
        action()
    }
}
