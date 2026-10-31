//
//  StructureSectionAdapter+Menus.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension StructureSectionAdapter {
    // The grid adds Copy, Duplicate, Delete and Undo Delete from its commands; these are the schema's own.
    // The copies act on every targeted row, Open and the moves on the clicked one; nil when that is not known.
    func rowMenuItems(for rowIDs: [RowID], clickedRow: RowID?) -> [NSMenuItem] {
        guard !rowIDs.isEmpty else { return [] }
        let indices = sourceIndices(of: rowIDs)
        let tab = section
        let clicked = clickedRow.flatMap(sourceIndex(of:))
        if let clicked, manager.deleteInsertState(for: clicked, tab: tab).isDeleted {
            return []
        }

        var items = [
            menuItem(String(localized: "Copy Name")) { [weak self] in self?.copyNames(indices) },
            menuItem(String(localized: "Copy Definition")) { [weak self] in self?.copyDefinitions(indices) },
            copyAsItem(indices),
        ]

        if tab == .foreignKeys, let clicked, manager.workingForeignKeys.indices.contains(clicked) {
            let referenced = manager.workingForeignKeys[clicked].referencedTable
            if !referenced.isEmpty {
                items.append(.separator())
                items.append(menuItem(String(format: String(localized: "Open %@"), referenced)) { [weak self] in
                    self?.navigateToForeignKey(sourceIndex: clicked)
                })
            }
        }

        let moves = columnMoveItems(movingRow: clicked)
        if !moves.isEmpty {
            items.append(.separator())
            items.append(contentsOf: moves)
        }
        return items
    }

    // Moving by menu gives the keyboard and VoiceOver the reorder a drag gives the pointer.
    private func columnMoveItems(movingRow row: Int?) -> [NSMenuItem] {
        guard section == .columns, !context.isCreatingTable else { return [] }
        let reorder = model.configuration.rowReorder
        guard reorder.isEnabled || reorder.unavailableReason != nil else { return [] }
        let count = manager.workingColumns.count
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
            self?.editor?.moveColumn(from: row, to: ColumnMove.dropIndex(movingRow: row, direction))
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
            changeManager: manager,
            tab: section,
            databaseType: context.databaseType,
            additionalFields: includingPrimaryKey ? [.primaryKey] : [],
            serverSupport: serverSupport
        )
    }

    func copyNames(_ indices: [Int]) {
        let provider = unsortedProvider(includingPrimaryKey: false)
        let names = indices.sorted().compactMap { provider.row(at: $0)?.first ?? nil }
        guard !names.isEmpty else { return }
        ClipboardService.shared.writeText(names.joined(separator: "\n"))
    }

    func copyDefinitions(_ indices: [Int]) {
        guard let driver = DatabaseManager.shared.driver(for: context.connection.id) else { return }
        var definitions: [String] = []
        for index in indices.sorted() {
            switch section {
            case .columns:
                guard manager.workingColumns.indices.contains(index),
                      let sql = driver.generateColumnDefinitionSQL(column: manager.workingColumns[index].toPlugin())
                else { continue }
                definitions.append(sql)
            case .indexes:
                guard manager.workingIndexes.indices.contains(index),
                      let sql = driver.generateIndexDefinitionSQL(
                          index: manager.workingIndexes[index].toPlugin(), tableName: context.tableName
                      )
                else { continue }
                definitions.append(sql)
            case .foreignKeys:
                guard manager.workingForeignKeys.indices.contains(index),
                      let sql = driver.generateForeignKeyDefinitionSQL(fk: manager.workingForeignKeys[index].toPlugin())
                else { continue }
                definitions.append(sql)
            case .checkConstraints:
                guard manager.workingCheckConstraints.indices.contains(index) else { continue }
                let constraint = manager.workingCheckConstraints[index]
                definitions.append("CONSTRAINT \(driver.quoteIdentifier(constraint.name)) CHECK (\(constraint.expression))")
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

    // The definitions ride on the structure pasteboard type, so Paste can stage them again.
    func copyRows(_ rowIDs: [RowID], to pasteboard: NSPasteboard = .general) {
        guard !rowIDs.isEmpty else { return }
        let ordered = rowIDs.sorted { (model.displayIndex(of: $0) ?? .max) < (model.displayIndex(of: $1) ?? .max) }
        let indices = sourceIndices(of: ordered)
        let encoder = JSONEncoder()
        let encoded: Data?
        switch section {
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
        }

        let rows = model.rows
        let lines = ordered.compactMap { rowID -> String? in
            rows.row(withID: rowID)?.values.map { $0.asText ?? "NULL" }.joined(separator: "\t")
        }

        let item = NSPasteboardItem()
        if let encoded, let json = String(data: encoded, encoding: .utf8) {
            item.setString(json, forType: StructurePasteboard.definitionsType)
            item.setString(context.databaseType.rawValue, forType: StructurePasteboard.sourceDatabaseType)
        }
        if !lines.isEmpty {
            item.setString(lines.joined(separator: "\n"), forType: .string)
        }
        guard !item.types.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    // Pasting several definitions is one undo step.
    func pasteRows(from pasteboard: NSPasteboard = .general) {
        guard canEdit, canAdd, let data = pasteboard.data(forType: StructurePasteboard.definitionsType) else { return }
        let source = pasteboard.string(forType: StructurePasteboard.sourceDatabaseType).map(DatabaseType.init(rawValue:))
        manager.performAsOneUndoStep {
            stagePasted(data, from: source)
        }
        editor?.definitionsDidChange()
    }

    private func stagePasted(_ data: Data, from source: DatabaseType?) {
        let decoder = JSONDecoder()
        switch section {
        case .columns:
            guard let columns = try? decoder.decode([EditableColumnDefinition].self, from: data) else { return }
            for column in columns {
                manager.addColumn(column.withNewIdentity())
            }
        case .indexes:
            guard let indexes = try? decoder.decode([EditableIndexDefinition].self, from: data) else { return }
            for index in indexes {
                manager.addIndex(index.pasted(from: source, into: context.databaseType))
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
        }
    }
}

enum StructurePasteboard {
    static let definitionsType = NSPasteboard.PasteboardType("com.TablePro.structure")
    static let sourceDatabaseType = NSPasteboard.PasteboardType("com.TablePro.structure.database-type")

    static var canPaste: Bool {
        NSPasteboard.general.data(forType: definitionsType) != nil
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
