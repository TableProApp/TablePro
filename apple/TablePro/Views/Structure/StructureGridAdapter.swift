//
//  StructureGridAdapter.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// Feeds the Structure tab's grid from the session's working definitions and writes its edits back,
// always by the definition a row names, never by where the row sits on screen.
@MainActor
final class StructureGridAdapter {
    let model: DataGridModel
    let store: StructureGridStateStore
    let structureChangeManager: StructureChangeManager
    let connection: DatabaseConnection
    let tableName: String
    let databaseName: String
    let schemaName: String?
    let objectKind: TableInfo.TableType
    let isSessionBound: Bool
    let referenceMenus: ForeignKeyReferenceMenus

    weak var session: StructureEditingSession?
    weak var coordinator: MainContentCoordinator?
    // Installed by the mounted view while a column may be moved; it owns the reorder flow and its sheets.
    var moveRowHandler: ((Int, Int) -> Void)?

    private(set) var provider: StructureRowProvider
    private var snapshot = StructureGridSnapshot()
    private let changeTracking: StructureGridChangeState
    private let changeState: AnyChangeManager

    init(
        structureChangeManager: StructureChangeManager,
        connection: DatabaseConnection,
        tableName: String,
        databaseName: String,
        schemaName: String?,
        objectKind: TableInfo.TableType,
        isSessionBound: Bool
    ) {
        self.structureChangeManager = structureChangeManager
        self.connection = connection
        self.tableName = tableName
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.objectKind = objectKind
        self.isSessionBound = isSessionBound
        let store = StructureGridStateStore()
        self.store = store
        self.model = DataGridModel(store: store)
        self.referenceMenus = ForeignKeyReferenceMenus(connectionId: connection.id, databaseType: connection.type)
        self.changeTracking = StructureGridChangeState(manager: structureChangeManager)
        self.changeState = AnyChangeManager(changeTracking)
        self.provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: .columns,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted
        )
        referenceMenus.schemaName = schemaName
        // Read when a list lands, not captured: the view hands the coordinator over on every appearance.
        referenceMenus.onListsChanged = { [weak self] in
            self?.coordinator?.inspectorRowSourceRevision += 1
        }
        model.dataSource = self
        model.actions = self
    }

    // MARK: - State

    // The sub-tab whose rows the grid shows. The session's selection moves first and refresh() follows, so every
    // write, menu and command reads this, never the incoming sub-tab (an open edit commits into the rows it was on).
    var selectedTab: StructureTab { store.subTab }
    private var serverSupport: StructureServerSupport { session?.serverSupport ?? .unrestricted }
    private var searchText: String { session?.searchText ?? "" }
    private var sortDescriptor: StructureSortDescriptor? { session?.sortDescriptor }

    var editGate: StructureEditGate {
        StructureEditGate(
            databaseType: connection.type, objectKind: objectKind, schema: schemaName, isSessionBound: isSessionBound
        )
    }

    var canEditForeignKeys: Bool {
        editGate.allows(.addForeignKey)
    }

    var canStageAddForSelectedTab: Bool {
        guard let adding = StructureFooterPolicy.operation(forAdding: selectedTab) else { return false }
        return editGate.allows(adding)
    }

    var canStageRemoveForSelectedTab: Bool {
        guard let removing = StructureFooterPolicy.operation(forRemoving: selectedTab) else { return false }
        return editGate.allows(removing)
    }

    var canEdit: Bool {
        editGate.allowsAnyEdit && !structureChangeManager.isHeldForSave
    }

    var lockedFieldIndices: Set<Int> {
        editGate.lockedFieldIndices(
            on: selectedTab,
            orderedFields: provider.orderedColumnFields,
            fieldCount: provider.columns.count
        )
    }

    var editRefusal: String? {
        if structureChangeManager.isHeldForSave { return StructureFooterPolicy.savingReason }
        guard !editGate.allowsAnyEdit else { return nil }
        return editGate.resolve(.renameColumn).unavailableReason
    }

    var columnReorderAvailability: ColumnReorderAvailability {
        ColumnReorderPolicy.resolve(
            support: PluginManager.shared.columnReorderSupport(for: connection.type),
            engineName: connection.type.displayName,
            isColumnsTab: selectedTab == .columns,
            kindRefusal: editGate.kindRefusal(.reorderColumns),
            canEditSchema: editGate.canEditSchema,
            hasStagedChanges: structureChangeManager.hasChanges,
            isRearranged: !searchText.isEmpty || sortDescriptor != nil || store.valueFilter.isActive
        )
    }

    var showsGrid: Bool {
        selectedTab != .ddl && selectedTab != .triggers && selectedTab != .parts
    }

    // MARK: - Refresh

    // Called whenever the working definitions, the sub-tab, the search, the sort or the edit gate moved.
    func refresh() {
        let tab = session?.selectedTab ?? store.subTab
        if store.subTab != tab {
            model.commitEditing()
            store.switchSubTab(to: tab)
        }
        changeTracking.tab = tab
        changeTracking.rowCount = StructureGridEdits.rowCount(on: tab, manager: structureChangeManager)

        let provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: tab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: serverSupport,
            filterText: searchText.isEmpty ? nil : searchText,
            sortDescriptor: sortDescriptor
        )
        self.provider = provider
        let rows = provider.asTableRows()
        let states = rows.rows.map { row in
            StructureGridEdits.visualState(
                sourceIndex: StructureRowProvider.sourceIndex(of: row.id) ?? -1,
                tab: tab,
                manager: structureChangeManager,
                orderedFields: provider.orderedColumnFields,
                tintsModifiedFields: true
            )
        }
        model.configuration = makeConfiguration(provider: provider)
        let previous = snapshot
        snapshot = StructureGridSnapshot(rows: rows, states: states)
        model.applyHeldSnapshot(from: previous, to: snapshot)
        if previous.rows.rows != rows.rows || previous.states != states || previous.rows.columns != rows.columns {
            coordinator?.inspectorRowSourceRevision += 1
        }
    }

    private func makeConfiguration(provider: StructureRowProvider) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        let options = provider.customDropdownOptions
        configuration.dropdownColumns = provider.dropdownColumns
        configuration.typePickerColumns = provider.typePickerColumns
        configuration.customDropdownOptions = options.isEmpty ? nil : options
        configuration.lockedColumns = lockedColumns(provider: provider)
        configuration.editRefusalMessage = editRefusal
        configuration.isEditable = canEdit
        configuration.traits = DataGridEngineTraits(
            databaseType: connection.type,
            connectionScope: DatabaseScope(connectionId: connection.id, database: databaseName, schema: schemaName),
            looksUpUserDefinedTypes: true
        )
        let reorder = columnReorderAvailability
        configuration.rowReorder = DataGridRowReorder(
            isEnabled: reorder.isAvailable,
            unavailableReason: reorder.unavailableReason
        )
        configuration.commands = commands(reorderAvailable: reorder.isAvailable)
        return configuration
    }

    private func commands(reorderAvailable: Bool) -> Set<DataGridCommand> {
        var commands: Set<DataGridCommand> = [.valueFilter, .freezeColumns]
        guard showsGrid, !structureChangeManager.isHeldForSave else { return commands }
        if canStageAddForSelectedTab {
            commands.formUnion([.addRow, .duplicateRows, .pasteRows])
        }
        if canStageRemoveForSelectedTab {
            commands.formUnion([.deleteRows, .undoDelete])
        }
        if reorderAvailable {
            commands.insert(.moveRows)
        }
        return commands
    }

    private func lockedColumns(provider: StructureRowProvider) -> Set<String> {
        let headings = provider.columns
        let locked = editGate.lockedFieldIndices(
            on: selectedTab,
            orderedFields: provider.orderedColumnFields,
            fieldCount: headings.count
        )
        return Set(locked.compactMap { headings.indices.contains($0) ? headings[$0] : nil })
    }

    // MARK: - Rows

    func sourceIndices(of rowIDs: [RowID]) -> [Int] {
        rowIDs.compactMap(StructureRowProvider.sourceIndex(of:))
    }

    func menuOptions(sourceIndex: Int, field: Int) -> [GridMenuOption]? {
        switch selectedTab {
        case .indexes:
            guard structureChangeManager.workingIndexes.indices.contains(sourceIndex) else { return nil }
            return StructureRowProvider.indexMenuOptions(
                columnIndex: field,
                index: structureChangeManager.workingIndexes[sourceIndex],
                serverSupport: serverSupport
            )
        case .foreignKeys:
            guard canEditForeignKeys,
                  structureChangeManager.workingForeignKeys.indices.contains(sourceIndex) else { return nil }
            referenceMenus.origin = coordinator?.selectedTabScope
            return referenceMenus.options(
                columnIndex: field,
                foreignKey: structureChangeManager.workingForeignKeys[sourceIndex],
                tableColumns: structureChangeManager.workingColumns.map(\.name)
            )
        case .columns, .checkConstraints, .ddl, .parts, .triggers:
            return nil
        }
    }

    // MARK: - Commands

    @discardableResult
    func applyEdit(rowID: RowID, field: Int, text: String) -> Bool {
        guard canEdit, let sourceIndex = StructureRowProvider.sourceIndex(of: rowID) else { return false }
        let applied = write(text, field: field, sourceIndex: sourceIndex)
        refresh()
        return applied
    }

    private func write(_ text: String, field: Int, sourceIndex: Int) -> Bool {
        let tab = selectedTab
        guard field >= 0,
              !editGate.locksField(at: field, on: tab, orderedFields: provider.orderedColumnFields),
              !structureChangeManager.deleteInsertState(for: sourceIndex, tab: tab).isDeleted else { return false }
        let changedReference = StructureGridEdits.apply(
            text,
            field: field,
            sourceIndex: sourceIndex,
            tab: tab,
            manager: structureChangeManager,
            orderedFields: provider.orderedColumnFields,
            connection: connection
        )
        if let changedReference {
            referenceMenus.origin = coordinator?.selectedTabScope
            referenceMenus.prefetchReferencedColumns(
                of: changedReference.referencedTable, schema: changedReference.referencedSchema
            )
        }
        return true
    }

    func deleteRows(_ rowIDs: [RowID]) {
        guard !rowIDs.isEmpty, showsGrid else {
            model.clearSelection()
            return
        }
        let allowed: Bool
        switch selectedTab {
        case .columns: allowed = editGate.allows(.dropColumn)
        case .indexes: allowed = editGate.allows(.dropIndex)
        case .foreignKeys: allowed = canEditForeignKeys
        case .checkConstraints: allowed = editGate.allows(.dropCheckConstraint)
        case .ddl, .parts, .triggers: allowed = false
        }
        guard allowed else { return }
        let displayRows = IndexSet(rowIDs.compactMap { model.displayIndex(of: $0) })
        let countBefore = model.rowCount
        StructureGridEdits.delete(
            sourceIndices: sourceIndices(of: rowIDs), tab: selectedTab, manager: structureChangeManager
        )
        refresh()
        selectAfterDeleting(displayRows, countBefore: countBefore)
    }

    private func selectAfterDeleting(_ displayRows: IndexSet, countBefore: Int) {
        let remaining = countBefore - displayRows.count
        guard remaining > 0, let minRow = displayRows.first, let maxRow = displayRows.last else {
            model.clearSelection()
            return
        }
        let target = maxRow < remaining ? maxRow : (minRow > 0 ? minRow - 1 : 0)
        guard let rowID = model.rowID(at: target) else {
            model.clearSelection()
            return
        }
        model.selectRows([rowID])
    }

    func addRow() {
        guard canStageAddForSelectedTab else { return }
        StructureGridEdits.addRow(on: selectedTab, manager: structureChangeManager)
        refresh()
    }

    func duplicateRows(_ rowIDs: [RowID]) {
        guard canStageAddForSelectedTab else { return }
        StructureGridEdits.duplicate(
            sourceIndices: sourceIndices(of: rowIDs), tab: selectedTab, manager: structureChangeManager
        )
        refresh()
    }

    func undoDelete(_ rowIDs: [RowID]) {
        for index in sourceIndices(of: rowIDs) {
            structureChangeManager.undoDelete(for: selectedTab, at: index)
        }
        refresh()
    }

    private var undoesStructureEdits: Bool {
        selectedTab != .ddl && selectedTab != .triggers
    }

    // The comment bar shows on every sub-tab, so its step undoes even where no grid is on screen.
    func undo() {
        guard undoesStructureEdits || structureChangeManager.undoesTableCommentNext else { return }
        model.commitEditing()
        structureChangeManager.undo()
        refresh()
    }

    func redo() {
        guard undoesStructureEdits || structureChangeManager.redoesTableCommentNext else { return }
        model.commitEditing()
        structureChangeManager.redo()
        refresh()
    }

    func navigateToForeignKey(sourceIndex: Int) {
        guard structureChangeManager.workingForeignKeys.indices.contains(sourceIndex), let coordinator else { return }
        let foreignKey = structureChangeManager.workingForeignKeys[sourceIndex]
        guard let origin = coordinator.selectedTabScope else {
            coordinator.openTableTab(foreignKey.referencedTable, schema: foreignKey.referencedSchema)
            return
        }
        let target = ForeignKeyTargetScope.resolve(
            origin: origin, referencedSchema: foreignKey.referencedSchema, databaseType: connection.type
        )
        coordinator.openTableTab(foreignKey.referencedTable, schema: target.schema, database: target.database)
    }

    func releaseViewWiring() {
        moveRowHandler = nil
        coordinator = nil
    }
}

// MARK: - DataGridDataSource

extension StructureGridAdapter: DataGridDataSource {
    var gridRows: TableRows { snapshot.rows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridVisualState(for rowID: RowID) -> RowVisualState? {
        snapshot.state(for: rowID)
    }

    func gridMenuOptions(for rowID: RowID, column: DataGridColumn) -> [GridMenuOption]? {
        guard let sourceIndex = StructureRowProvider.sourceIndex(of: rowID) else { return nil }
        return menuOptions(sourceIndex: sourceIndex, field: column.dataIndex)
    }
}

// MARK: - DataGridActions

extension StructureGridAdapter: DataGridActions {
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        guard canEdit, !edits.isEmpty else { return false }
        var applied = false
        let writeAll = {
            for edit in edits {
                guard let sourceIndex = StructureRowProvider.sourceIndex(of: edit.rowID) else { continue }
                if self.write(edit.newValue.asText ?? "", field: edit.dataIndex, sourceIndex: sourceIndex) {
                    applied = true
                }
            }
        }
        if edits.count > 1 {
            structureChangeManager.performAsOneUndoStep(writeAll)
        } else {
            writeAll()
        }
        refresh()
        return applied
    }

    func gridDeleteRows(_ rowIDs: [RowID]) {
        deleteRows(rowIDs)
    }

    func gridUndoDelete(_ rowIDs: [RowID]) {
        undoDelete(rowIDs)
    }

    func gridAddRow() {
        addRow()
    }

    func gridDuplicateRows(_ rowIDs: [RowID]) {
        duplicateRows(rowIDs)
    }

    func gridCanPasteRows() -> Bool {
        canStageAddForSelectedTab && TableStructureView.canPasteStructureRows
    }

    func gridPasteRows() {
        pasteRows()
    }

    // A move is offered only while nothing filters or sorts the list, so the drop index is a working index.
    func gridMoveRow(from source: RowID, toDisplayIndex destination: Int) {
        guard let sourceIndex = StructureRowProvider.sourceIndex(of: source) else { return }
        moveRowHandler?(sourceIndex, destination)
    }

    // The provider sorts by one column, so a secondary key the header appended is dropped.
    func gridSortDidChange(_ sort: SortState) {
        guard let session else { return }
        if let primary = sort.columns.first {
            session.sortDescriptor = StructureSortDescriptor(
                column: primary.columnIndex, ascending: primary.direction == .ascending
            )
            store.sortState = SortState(columns: [primary], source: .user)
        } else {
            session.sortDescriptor = nil
            store.sortState = SortState(columns: [], source: .user)
        }
        refresh()
    }

    // A value filter rearranges the list, which withdraws the column move.
    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        apply()
        model.configuration = makeConfiguration(provider: provider)
    }

    func gridRowMenuItems(for rowIDs: [RowID]) -> [NSMenuItem] {
        structureRowMenuItems(for: rowIDs)
    }

    func gridEmptySpaceMenu() -> NSMenu? {
        makeEmptySpaceMenu()
    }
}
