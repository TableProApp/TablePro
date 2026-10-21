//
//  ERDiagramViewModel+Editing.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

struct ERDiagramPendingPlacement: Equatable {
    let point: CGPoint
    var tableName: String?
}

struct ERDiagramColumnHit: Equatable {
    let nodeId: UUID
    let tableName: String
    let columnName: String
    let rowRect: CGRect
    let isDropped: Bool
    var canHoldKey = false
}

struct ERDiagramForeignKeyDraft: Equatable {
    let table: String
    var column: String
    var referencedTable: String
    var referencedColumn: String
    var name: String
    var onDelete: EditableForeignKeyDefinition.ReferentialAction = .noAction
    var onUpdate: EditableForeignKeyDefinition.ReferentialAction = .noAction
}

enum ERDiagramEditSheet: Identifiable, Equatable {
    case addForeignKey(ERDiagramForeignKeyDraft)
    case addColumn(table: String)
    case renameColumn(table: String, column: String)

    var id: String {
        switch self {
        case .addForeignKey(let draft): "fk:\(draft.table).\(draft.column)"
        case .addColumn(let table): "add:\(table)"
        case .renameColumn(let table, let column): "rename:\(table).\(column)"
        }
    }
}

extension ERDiagramViewModel {
    var edits: ERDiagramSchemaEdits? {
        if let existing = editsIfCreated { return existing }
        guard let connection = editingConnection else { return nil }
        let created = ERDiagramSchemaEdits(
            connection: connection,
            databaseName: scope?.database ?? databaseName,
            schemaName: scope?.schema ?? schemaName,
            provider: services.databaseManager,
            objectKind: { [weak self] table in self?.kind(of: table) ?? .table }
        )
        created.onChange = { [weak self] in self?.refreshStagedOverlay() }
        created.onAppliedOutsideSave = { [weak self] in
            Task { await self?.refresh() }
        }
        adoptEdits(created)
        return created
    }

    func kind(of table: String) -> TableInfo.TableType {
        objectKinds[table] ?? .table
    }

    // Nothing is offered while a save runs, the way the Structure tab locks its grid.
    func allows(_ operation: StructureEditOperation, on table: String) -> Bool {
        guard let connection = editingConnection, editsIfCreated?.isSaving != true else { return false }
        return StructureEditGate(databaseType: connection.type, objectKind: kind(of: table)).allows(operation)
    }

    var canLinkColumns: Bool {
        guard loadState == .loaded, let connection = editingConnection, editsIfCreated?.isSaving != true else {
            return false
        }
        return StructureEditGate(databaseType: connection.type, objectKind: .table).allows(.addForeignKey)
    }

    private var canCreateTable: Bool {
        guard let coordinator, !coordinator.safeModeLevel.blocksAllWrites else { return false }
        return CreateTableEligibility.canCreateTable(with: services.databaseManager.driver(for: connectionId))
    }

    // MARK: - Hit Testing

    func node(withId id: UUID) -> ERTableNode? {
        graph.nodes.first { $0.id == id }
    }

    func edge(withId id: UUID) -> EREdge? {
        graph.edges.first { $0.id == id }
    }

    func columnHit(at point: CGPoint) -> ERDiagramColumnHit? {
        guard let nodeId = nodeId(at: point),
              let rect = cachedNodeRects[nodeId],
              let node = node(withId: nodeId)
        else { return nil }
        let offset = point.y - rect.minY - ERDiagramLayout.headerHeight
        guard offset >= 0 else { return nil }
        let index = Int(offset / ERDiagramLayout.columnRowHeight)
        guard node.displayColumns.indices.contains(index) else { return nil }
        let column = node.displayColumns[index]
        return ERDiagramColumnHit(
            nodeId: nodeId,
            tableName: node.tableName,
            columnName: column.name,
            rowRect: CGRect(
                x: rect.minX,
                y: rect.minY + ERDiagramLayout.headerHeight + CGFloat(index) * ERDiagramLayout.columnRowHeight,
                width: rect.width,
                height: ERDiagramLayout.columnRowHeight
            ),
            isDropped: column.stagedEdit == .dropped,
            canHoldKey: column.stagedEdit != .dropped && allows(.addForeignKey, on: node.tableName)
        )
    }

    func edgeId(at point: CGPoint, tolerance: CGFloat) -> UUID? {
        ERDiagramEdgeRenderer.edgeId(
            at: point,
            tolerance: tolerance,
            edges: graph.edges,
            nodeRects: cachedNodeRects,
            nodeIndex: graph.nodeIndex
        )
    }

    func selectNode(_ id: UUID?) {
        selectedEdgeId = nil
        selectedNodeId = id
    }

    func selectEdge(_ id: UUID?) {
        selectedNodeId = nil
        selectedEdgeId = id
    }

    // MARK: - Menus

    func menuSections(for target: ERDiagramMenuTarget) -> [[ERDiagramMenuEntry]] {
        switch target {
        case .table(let table):
            return tableSections(table)
        case .column(let table, let column):
            let isDropped = isColumnDropped(column, in: table)
            var editItems: [ERDiagramMenuEntry] = []
            if allows(.addForeignKey, on: table), !isDropped {
                editItems.append(ERDiagramMenuEntry(
                    String(localized: "Add Foreign Key…"), .addForeignKey(table: table, column: column)
                ))
            }
            if allows(.renameColumn, on: table), !isDropped {
                editItems.append(ERDiagramMenuEntry(
                    String(localized: "Rename Column…"), .renameColumn(table: table, column: column)
                ))
            }
            // Destructive items go last, behind a separator, the way macOS sets them apart.
            var dropItems = graph.edges
                .filter { $0.fromTable == table && $0.fromColumn == column && canDrop($0) }
                .map {
                    ERDiagramMenuEntry(
                        String(format: String(localized: "Delete Foreign Key %@"), $0.fkName),
                        .dropForeignKey($0.id)
                    )
                }
            if allows(.dropColumn, on: table), !isDropped {
                dropItems.append(ERDiagramMenuEntry(
                    String(localized: "Delete Column"), .dropColumn(table: table, column: column)
                ))
            }
            return [editItems, addColumnItems(table), openItems(table), dropItems]
        case .edge(let id):
            guard let edge = edge(withId: id) else { return [] }
            if edge.cardinality == .manyToMany {
                return [openItems(edge.fkName)]
            }
            let structure = ERDiagramMenuEntry(
                String(format: String(localized: "Show Structure of %@"), edge.fromTable),
                .showStructure(edge.fromTable)
            )
            let dropItems = canDrop(edge)
                ? [ERDiagramMenuEntry(String(localized: "Delete Foreign Key"), .dropForeignKey(id))]
                : []
            return [[structure], dropItems]
        case .canvas(let point):
            let createItems = canCreateTable
                ? [ERDiagramMenuEntry(String(localized: "New Table…"), .newTable(at: point))]
                : []
            return [createItems, [ERDiagramMenuEntry(String(localized: "Refresh"), .refresh)]]
        }
    }

    private func tableSections(_ table: String) -> [[ERDiagramMenuEntry]] {
        [
            openItems(table),
            addColumnItems(table),
            [ERDiagramMenuEntry(String(localized: "Copy Name"), .copyName(table))]
        ]
    }

    private func openItems(_ table: String) -> [ERDiagramMenuEntry] {
        [
            ERDiagramMenuEntry(String(localized: "Open Table"), .openTable(table)),
            ERDiagramMenuEntry(String(localized: "Show Structure"), .showStructure(table))
        ]
    }

    private func addColumnItems(_ table: String) -> [ERDiagramMenuEntry] {
        allows(.addColumn, on: table) ? [ERDiagramMenuEntry(String(localized: "Add Column…"), .addColumn(table: table))] : []
    }

    private func isColumnDropped(_ column: String, in table: String) -> Bool {
        guard let id = graph.nodeIndex[table], let node = node(withId: id) else { return false }
        return node.columns.first { $0.name == column }?.stagedEdit == .dropped
    }

    private func canDrop(_ edge: EREdge) -> Bool {
        edge.cardinality != .manyToMany && edge.stagedEdit != .dropped && allows(.dropForeignKey, on: edge.fromTable)
    }

    func perform(_ command: ERDiagramMenuCommand) {
        switch command {
        case .openTable(let table):
            openTable(table)
        case .showStructure(let table):
            open(table, showStructure: true)
        case .copyName(let table):
            ClipboardService.shared.writeText(table)
        case .addColumn(let table):
            editSheet = .addColumn(table: table)
        case .renameColumn(let table, let column):
            editSheet = .renameColumn(table: table, column: column)
        case .dropColumn(let table, let column):
            stage { try await $0.dropColumn(column, on: table) }
        case .addForeignKey(let table, let column):
            beginForeignKey(from: table, column: column, to: nil)
        case .dropForeignKey(let id):
            dropForeignKey(id)
        case .newTable(let point):
            requestNewTable(at: point)
        case .refresh:
            Task { await refresh() }
        }
    }

    func openTable(_ table: String) {
        open(table, showStructure: false)
    }

    // A view opens as a view, so its tab offers what the view allows and shows its own DDL.
    private func open(_ table: String, showStructure: Bool) {
        let kind = kind(of: table)
        coordinator?.openTableTab(
            table,
            schema: schemaName,
            database: databaseName,
            showStructure: showStructure,
            isView: !kind.allowsRowEditing,
            objectType: kind,
            forceNonPreview: true
        )
    }

    private func requestNewTable(at point: CGPoint) {
        guard let coordinator else { return }
        pendingPlacement = ERDiagramPendingPlacement(point: point)
        coordinator.createNewTable(databaseName: scope?.database ?? databaseName, schemaName: scope?.schema ?? schemaName)
    }

    // MARK: - Foreign Keys

    var canDeleteSelection: Bool {
        guard let id = selectedEdgeId, let edge = edge(withId: id) else { return false }
        return canDrop(edge)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        guard canDeleteSelection, let id = selectedEdgeId else { return false }
        dropForeignKey(id)
        return true
    }

    private func dropForeignKey(_ id: UUID) {
        guard let edge = edge(withId: id), canDrop(edge) else { return }
        stage {
            try await $0.dropForeignKey(
                named: edge.fkName, column: edge.fromColumn, referencing: edge.toTable, on: edge.fromTable
            )
        }
    }

    func canLink(from source: ERDiagramColumnHit, to target: ERDiagramColumnHit) -> Bool {
        source.canHoldKey && !target.isDropped && kind(of: target.tableName).isForeignKeyTarget
            && !(source.tableName == target.tableName && source.columnName == target.columnName)
    }

    func beginForeignKey(from table: String, column: String, to target: ERDiagramColumnHit?) {
        let tables = referenceableTables
        let referencedTable = target?.tableName
            ?? tables.first { $0 != table }
            ?? table
        let referencedColumn = target?.columnName ?? defaultReferencedColumn(in: referencedTable)
        editSheet = .addForeignKey(ERDiagramForeignKeyDraft(
            table: table,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            name: defaultForeignKeyName(table: table, column: column)
        ))
    }

    var referenceableTables: [String] {
        stagedFullGraph.nodes.map(\.tableName).filter { kind(of: $0).isForeignKeyTarget }.sorted()
    }

    func columnNames(of table: String) -> [String] {
        guard let id = stagedFullGraph.nodeIndex[table],
              let node = stagedFullGraph.nodes.first(where: { $0.id == id })
        else { return [] }
        return node.columns.filter { $0.stagedEdit != .dropped }.map(\.name)
    }

    func defaultReferencedColumn(in table: String) -> String {
        guard let id = stagedFullGraph.nodeIndex[table],
              let node = stagedFullGraph.nodes.first(where: { $0.id == id })
        else { return "" }
        let keys = node.columns.filter { $0.isPrimaryKey && $0.stagedEdit != .dropped }
        return (keys.count == 1 ? keys.first : node.columns.first { $0.stagedEdit != .dropped })?.name ?? ""
    }

    // MySQL wants a foreign key's name unique in the whole database, so it is checked against every key drawn.
    func defaultForeignKeyName(table: String, column: String) -> String {
        let taken = Set(stagedFullGraph.edges.filter { $0.stagedEdit != .dropped }.map(\.fkName))
        let base = String("fk_\(table)_\(column)".prefix(Self.identifierLimit))
        guard taken.contains(base) else { return base }
        for suffix in 2...999 {
            let tail = "_\(suffix)"
            let candidate = String(base.prefix(Self.identifierLimit - tail.count)) + tail
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    // A key staged for dropping gives its name back, so it can be replaced in the same save.
    func isForeignKeyNameTaken(_ name: String) -> Bool {
        stagedFullGraph.edges.contains { $0.fkName == name && $0.stagedEdit != .dropped }
    }

    private static let identifierLimit = 63

    private var stagedFullGraph: ERDiagramGraph {
        ERDiagramStagedOverlay.apply(edits?.tableEdits() ?? [:], to: savedGraph)
    }

    func stageForeignKey(_ draft: ERDiagramForeignKeyDraft) {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        foreignKey.columns = [draft.column]
        foreignKey.referencedTable = draft.referencedTable
        foreignKey.referencedColumns = [draft.referencedColumn]
        foreignKey.onDelete = draft.onDelete
        foreignKey.onUpdate = draft.onUpdate
        stage { try await $0.addForeignKey(foreignKey, to: draft.table) }
    }

    // MARK: - Columns

    func stageColumn(_ column: EditableColumnDefinition, in table: String) {
        stage { try await $0.addColumn(column, to: table) }
    }

    func stageRename(of column: String, to newName: String, in table: String) {
        stage { try await $0.renameColumn(column, to: newName, on: table) }
    }

    func isColumnNameTaken(_ name: String, in table: String, ignoring current: String? = nil) -> Bool {
        let existing = edits?.workingColumns(of: table)?.map(\.name) ?? columnNames(of: table)
        return existing.contains { $0 != current && $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func stage(_ body: @escaping @MainActor (ERDiagramSchemaEdits) async throws -> Void) {
        guard let edits else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.finishStaging(id) }
            do {
                try await body(edits)
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could Not Stage the Change"),
                    message: error.localizedDescription,
                    window: self?.coordinator?.contentWindow
                )
            }
        }
        track(task, id: id)
    }

    // MARK: - Save, Preview, Undo

    func applyStagedEdits(coordinator: MainContentCoordinator?) async -> StructureSaveOutcome {
        await awaitPendingStaging()
        guard let edits = editsIfCreated, edits.hasChanges else { return .nothingToApply }
        let result = await edits.apply(coordinator: coordinator)
        if !result.appliedTables.isEmpty {
            await refresh()
        }
        // Work staged while the reload ran is still unsaved, so a close must not go ahead over it.
        if result.outcome == .applied, holdsUnsavedWork {
            return .refused
        }
        return result.outcome
    }

    func previewStagedEdits(coordinator: MainContentCoordinator) async {
        await awaitPendingStaging()
        guard let edits = editsIfCreated, edits.hasChanges else { return }
        let statements = await edits.previewStatements()
        guard coordinator.activeSheet == nil else { return }
        coordinator.toolbarState.previewStatements = statements
        coordinator.activeSheet = .sqlPreview
    }

    func discardStagedEdits() {
        editsIfCreated?.discardAll()
    }

    var canUndoStagedEdit: Bool { editsIfCreated?.canUndo ?? false }
    var canRedoStagedEdit: Bool { editsIfCreated?.canRedo ?? false }

    func undoStagedEdit() {
        editsIfCreated?.undo()
    }

    func redoStagedEdit() {
        editsIfCreated?.redo()
    }
}
