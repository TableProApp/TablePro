//
//  CreateTableGridAdapter.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// The Create Table grid: every row is a definition the draft holds, edited by the definition a row
// names. Held by the draft, so the grid's state survives the tab being switched away and back.
@MainActor
final class CreateTableGridAdapter {
    let model: DataGridModel
    let store: StructureGridStateStore
    let structureChangeManager: StructureChangeManager
    let connection: DatabaseConnection
    let referenceMenus: ForeignKeyReferenceMenus

    weak var coordinator: MainContentCoordinator?
    // Holds the catalog the Charset and Collation cells pick from, and the table's own character set.
    weak var draft: CreateTableDraft?
    var serverSupport = StructureServerSupport.unrestricted
    private(set) var structureTab: StructureTab = .columns

    var schemaName: String? {
        get { referenceMenus.schemaName }
        set { referenceMenus.schemaName = newValue }
    }

    private(set) var provider: StructureRowProvider
    private var sortDescriptor: StructureSortDescriptor?
    private var snapshot = StructureGridSnapshot()
    private let changeTracking: StructureGridChangeState
    private let changeState: AnyChangeManager

    init(structureChangeManager: StructureChangeManager, connection: DatabaseConnection) {
        self.structureChangeManager = structureChangeManager
        self.connection = connection
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
        referenceMenus.onListsChanged = { [weak self] in
            self?.coordinator?.inspectorRowSourceRevision += 1
        }
        model.dataSource = self
        model.actions = self
    }

    func select(_ tab: StructureTab) {
        guard tab != structureTab else { return }
        model.commitEditing()
        structureTab = tab
        sortDescriptor = nil
        store.switchSubTab(to: tab)
        store.sortState = SortState()
        refresh()
    }

    var characterSetContext: ColumnCharacterSetMenus.Context {
        ColumnCharacterSetMenus.Context(
            catalog: draft?.optionsCatalog ?? .idle,
            tableCharacterSet: draft?.tableOptions.charset
        )
    }

    func characterSetCatalogDidChange() {
        refresh()
        coordinator?.inspectorRowSourceRevision += 1
    }

    func refresh() {
        changeTracking.tab = structureTab
        changeTracking.rowCount = StructureGridEdits.rowCount(on: structureTab, manager: structureChangeManager)
        let provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: structureTab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: serverSupport,
            sortDescriptor: sortDescriptor,
            picksCharacterSets: ColumnCharacterSetMenus.offersMenus(characterSetContext.catalog)
        )
        self.provider = provider
        let rows = provider.asTableRows()
        let states = rows.rows.map { row in
            StructureGridEdits.visualState(
                sourceIndex: StructureRowProvider.sourceIndex(of: row.id) ?? -1,
                tab: structureTab,
                manager: structureChangeManager,
                orderedFields: provider.orderedColumnFields,
                tintsModifiedFields: false
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
        configuration.dropdownColumns = provider.dropdownColumns
        configuration.typePickerColumns = provider.typePickerColumns
        configuration.customDropdownOptions = provider.customDropdownOptions
        configuration.isEditable = true
        configuration.traits = DataGridEngineTraits(
            databaseType: connection.type,
            connectionScope: DatabaseScope(
                connectionId: connection.id,
                database: DatabaseManager.shared.browseDatabaseName(for: connection),
                schema: schemaName
            ),
            looksUpUserDefinedTypes: true
        )
        configuration.commands = [.addRow, .deleteRows, .valueFilter, .freezeColumns]
        return configuration
    }

    // MARK: - Commands

    func menuOptions(sourceIndex: Int, field: Int) -> [GridMenuOption]? {
        switch structureTab {
        case .indexes:
            guard structureChangeManager.workingIndexes.indices.contains(sourceIndex) else { return nil }
            return StructureRowProvider.indexMenuOptions(
                columnIndex: field,
                index: structureChangeManager.workingIndexes[sourceIndex],
                serverSupport: serverSupport
            )
        case .foreignKeys:
            guard structureChangeManager.workingForeignKeys.indices.contains(sourceIndex) else { return nil }
            return referenceMenus.options(
                columnIndex: field,
                foreignKey: structureChangeManager.workingForeignKeys[sourceIndex],
                tableColumns: structureChangeManager.workingColumns.map(\.name)
            )
        case .columns:
            guard structureChangeManager.workingColumns.indices.contains(sourceIndex),
                  provider.orderedColumnFields.indices.contains(field) else { return nil }
            return ColumnCharacterSetMenus.options(
                for: provider.orderedColumnFields[field],
                column: structureChangeManager.workingColumns[sourceIndex],
                context: characterSetContext
            )
        case .checkConstraints, .options, .ddl, .parts, .triggers:
            return nil
        }
    }

    func characterSetLockedFields(sourceIndex: Int) -> Set<Int> {
        guard structureTab == .columns, structureChangeManager.workingColumns.indices.contains(sourceIndex) else { return [] }
        return ColumnCharacterSetMenus.lockedFieldIndices(
            orderedFields: provider.orderedColumnFields,
            column: structureChangeManager.workingColumns[sourceIndex],
            catalog: characterSetContext.catalog
        )
    }

    @discardableResult
    func applyEdit(rowID: RowID, field: Int, text: String) -> Bool {
        guard let sourceIndex = StructureRowProvider.sourceIndex(of: rowID) else { return false }
        let applied = write(text, field: field, sourceIndex: sourceIndex)
        refresh()
        return applied
    }

    private func write(_ text: String, field: Int, sourceIndex: Int) -> Bool {
        let characterSets = characterSetContext
        guard field >= 0,
              !StructureGridEdits.refuses(
                  text,
                  field: field,
                  sourceIndex: sourceIndex,
                  tab: structureTab,
                  manager: structureChangeManager,
                  orderedFields: provider.orderedColumnFields,
                  characterSets: characterSets
              ) else { return false }
        let changedReference = StructureGridEdits.apply(
            text,
            field: field,
            sourceIndex: sourceIndex,
            tab: structureTab,
            manager: structureChangeManager,
            orderedFields: provider.orderedColumnFields,
            connection: connection,
            characterSets: characterSets
        )
        if let changedReference {
            referenceMenus.prefetchReferencedColumns(
                of: changedReference.referencedTable, schema: changedReference.referencedSchema
            )
        }
        return true
    }

    func addRow() {
        StructureGridEdits.addRow(on: structureTab, manager: structureChangeManager)
        refresh()
    }

    func deleteRows(_ rowIDs: [RowID]) {
        let indices = rowIDs.compactMap(StructureRowProvider.sourceIndex(of:))
        guard !indices.isEmpty else { return }
        let displayRows = IndexSet(rowIDs.compactMap { model.displayIndex(of: $0) })
        StructureGridEdits.delete(sourceIndices: indices, tab: structureTab, manager: structureChangeManager)
        refresh()
        let remaining = model.rowCount
        guard remaining > 0, let minRow = displayRows.first, let maxRow = displayRows.last else {
            model.clearSelection()
            return
        }
        let target = maxRow < remaining ? maxRow : (minRow > 0 ? minRow - 1 : 0)
        if let rowID = model.rowID(at: target) {
            model.selectRows([rowID])
        } else {
            model.clearSelection()
        }
    }

    func undo() {
        model.commitEditing()
        structureChangeManager.undo()
        refresh()
    }

    func redo() {
        model.commitEditing()
        structureChangeManager.redo()
        refresh()
    }
}

extension CreateTableGridAdapter: DataGridDataSource {
    var gridRows: TableRows { snapshot.rows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridVisualState(for rowID: RowID) -> RowVisualState? {
        snapshot.state(for: rowID)
    }

    func gridMenuOptions(for rowID: RowID, column: DataGridColumn) -> [GridMenuOption]? {
        guard let sourceIndex = StructureRowProvider.sourceIndex(of: rowID) else { return nil }
        let options = menuOptions(sourceIndex: sourceIndex, field: column.dataIndex)
        if structureTab == .columns, provider.orderedColumnFields.indices.contains(column.dataIndex),
           ColumnCharacterSetMenus.isCharacterSetField(provider.orderedColumnFields[column.dataIndex]) {
            draft?.retryOptionsCatalog()
        }
        return options
    }
}

extension CreateTableGridAdapter: DataGridActions {
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        let writes = edits.compactMap { edit -> (Int, Int, String)? in
            StructureRowProvider.sourceIndex(of: edit.rowID).map { ($0, edit.dataIndex, edit.newValue.asText ?? "") }
        }
        guard !writes.isEmpty else { return false }
        var applied = false
        let writeAll = {
            for (sourceIndex, field, text) in writes {
                let wrote = self.write(text, field: field, sourceIndex: sourceIndex)
                applied = applied || wrote
            }
        }
        if writes.count > 1 {
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

    func gridAddRow() {
        addRow()
    }

    func gridSortDidChange(_ sort: SortState) {
        if let primary = sort.columns.first {
            sortDescriptor = StructureSortDescriptor(column: primary.columnIndex, ascending: primary.direction == .ascending)
            store.sortState = SortState(columns: [primary], source: .user)
        } else {
            sortDescriptor = nil
            store.sortState = SortState(columns: [], source: .user)
        }
        refresh()
    }
}

extension CreateTableGridAdapter: InspectorRowSource {
    func inspectorRow(atDisplayRow displayRow: Int) -> InspectorRow? {
        guard let rowID = model.rowID(at: displayRow),
              let sourceIndex = StructureRowProvider.sourceIndex(of: rowID),
              let providerRow = provider.displayRow(ofSourceIndex: sourceIndex) else { return nil }
        return StructureInspectorRowBuilder.row(
            atDisplayRow: providerRow,
            tab: structureTab,
            provider: provider,
            canEditSchema: true,
            lockedFieldIndices: characterSetLockedFields(sourceIndex: sourceIndex),
            rowOptions: { menuOptions(sourceIndex: sourceIndex, field: $0) }
        )
    }

    func commitInspectorField(displayRow: Int, fieldIndex: Int, value: String?) {
        guard let rowID = model.rowID(at: displayRow) else { return }
        applyEdit(rowID: rowID, field: fieldIndex, text: value ?? "")
    }
}
