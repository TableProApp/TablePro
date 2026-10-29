//
//  StructureSectionAdapter.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// Feeds one section's grid from the working definitions and writes its edits back. A row is named by its
// definition's id, so a reload, a sort, a filter or a removed row above it never moves the selection.
@MainActor
final class StructureSectionAdapter {
    let section: StructureSection
    let model: DataGridModel
    let store: StructureGridStateStore
    let manager: StructureChangeManager
    let context: StructureEditingContext
    let referenceMenus: ForeignKeyReferenceMenus

    weak var editor: StructureDefinitionEditor?

    private(set) var provider: StructureRowProvider
    private var snapshot = StructureGridSnapshot()
    private var identities = StructureRowIdentities()
    private var sortDescriptor: StructureSortDescriptor?
    private let changeTracking: StructureGridChangeState
    private let changeState: AnyChangeManager

    init(
        section: StructureSection,
        manager: StructureChangeManager,
        context: StructureEditingContext,
        referenceMenus: ForeignKeyReferenceMenus,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        self.section = section
        self.manager = manager
        self.context = context
        self.referenceMenus = referenceMenus
        let store = StructureGridStateStore(section: section, defaults: defaults)
        self.store = store
        self.model = DataGridModel(store: store)
        self.changeTracking = StructureGridChangeState(manager: manager, section: section)
        self.changeState = AnyChangeManager(changeTracking)
        self.provider = StructureRowProvider(
            changeManager: manager,
            tab: section,
            databaseType: context.databaseType,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted
        )
        model.dataSource = self
        model.actions = self
    }

    // MARK: - State

    var serverSupport: StructureServerSupport { editor?.serverSupport ?? .unrestricted }
    private var searchText: String { editor?.searchText ?? "" }
    private var coordinator: MainContentCoordinator? { editor?.coordinator }

    var characterSetContext: ColumnCharacterSetMenus.Context {
        editor?.characterSetContext ?? ColumnCharacterSetMenus.Context(catalog: .idle, tableCharacterSet: nil)
    }

    var canAdd: Bool { context.allows(context.addOperation(for: section)) }
    var canRemove: Bool { context.allows(context.removeOperation(for: section)) }

    var canEdit: Bool {
        guard !manager.isHeldForSave, editor?.isReadOnly != true, editor?.isAwaitingBaseline != true else { return false }
        return context.isCreatingTable || context.editGate.allowsAnyEdit
    }

    var editRefusal: String? {
        if manager.isHeldForSave { return StructureFooterPolicy.savingReason }
        if editor?.isAwaitingBaseline == true { return String(localized: "The table is being read again after the save.") }
        if editor?.isReadOnly == true { return editor?.readOnlyReason }
        guard !context.isCreatingTable, !context.editGate.allowsAnyEdit else { return nil }
        return context.editGate.resolve(.renameColumn).unavailableReason
    }

    var lockedFieldIndices: Set<Int> {
        guard !context.isCreatingTable else { return [] }
        return context.editGate.lockedFieldIndices(
            on: section,
            orderedFields: provider.orderedColumnFields,
            fieldCount: provider.columns.count
        )
    }

    var columnReorderAvailability: ColumnReorderAvailability {
        ColumnReorderPolicy.resolve(
            support: PluginManager.shared.columnReorderSupport(for: context.databaseType),
            engineName: context.databaseType.displayName,
            isColumnsTab: section == .columns && !context.isCreatingTable,
            kindRefusal: context.editGate.kindRefusal(.reorderColumns),
            canEditSchema: context.editGate.canEditSchema && editor?.isReadOnly != true,
            hasStagedChanges: manager.hasChanges,
            isRearranged: !searchText.isEmpty || sortDescriptor != nil || store.valueFilter.isActive
        )
    }

    var rowCount: Int { StructureGridEdits.rowCount(on: section, manager: manager) }

    var visibleRowCount: Int { snapshot.rows.rows.count }

    // MARK: - Identity

    func rowID(forEntity id: UUID) -> RowID {
        identities.rowID(for: id)
    }

    func entityID(of rowID: RowID) -> UUID? {
        identities.entityID(of: rowID)
    }

    func sourceIndex(of rowID: RowID) -> Int? {
        guard let id = identities.entityID(of: rowID) else { return nil }
        return StructureGridEdits.sourceIndex(of: id, in: section, manager: manager)
    }

    func sourceIndices(of rowIDs: [RowID]) -> [Int] {
        rowIDs.compactMap(sourceIndex(of:))
    }

    var selectedEntityIDs: [UUID] {
        model.selection.affectedRows.compactMap { model.rowID(at: $0) }.compactMap(entityID(of:))
    }

    func select(entity id: UUID) {
        model.selectRows([rowID(forEntity: id)])
    }

    // MARK: - Refresh

    func refresh() {
        let entityIDs = StructureGridEdits.entityIDs(in: section, manager: manager)
        let rowIDs = entityIDs.map { identities.rowID(for: $0) }
        changeTracking.rowIDs = rowIDs

        let provider = StructureRowProvider(
            changeManager: manager,
            tab: section,
            databaseType: context.databaseType,
            additionalFields: [.primaryKey],
            serverSupport: serverSupport,
            filterText: searchText.isEmpty ? nil : searchText,
            sortDescriptor: sortDescriptor,
            picksCharacterSets: ColumnCharacterSetMenus.offersMenus(characterSetContext.catalog)
        )
        self.provider = provider
        let rows = provider.asTableRows { rowIDs.indices.contains($0) ? rowIDs[$0] : .existing(-1) }
        let states = provider.filteredToSourceMap.map { sourceIndex in
            StructureGridEdits.visualState(
                sourceIndex: sourceIndex,
                tab: section,
                manager: manager,
                orderedFields: provider.orderedColumnFields,
                tintsModifiedFields: !context.isCreatingTable
            )
        }
        model.configuration = makeConfiguration(provider: provider)
        let previous = snapshot
        snapshot = StructureGridSnapshot(rows: rows, states: states)
        model.applyHeldSnapshot(from: previous, to: snapshot)
    }

    private func makeConfiguration(provider: StructureRowProvider) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        let checkboxes = provider.booleanColumns
        let options = provider.customDropdownOptions.filter { !checkboxes.contains($0.key) }
        configuration.checkboxColumns = checkboxes
        configuration.dropdownColumns = provider.dropdownColumns.subtracting(checkboxes)
        configuration.typePickerColumns = provider.typePickerColumns
        configuration.customDropdownOptions = options.isEmpty ? nil : options
        configuration.marksEmptyText = false
        configuration.lockedColumns = lockedColumns(provider: provider)
        configuration.editRefusalMessage = editRefusal
        configuration.isEditable = canEdit
        configuration.fitsRows = true
        configuration.traits = DataGridEngineTraits(
            databaseType: context.databaseType,
            connectionScope: DatabaseScope(
                connectionId: context.connection.id, database: context.databaseName, schema: context.schemaName
            ),
            looksUpUserDefinedTypes: true
        )
        let reorder = columnReorderAvailability
        configuration.rowReorder = DataGridRowReorder(
            isEnabled: reorder.isAvailable,
            unavailableReason: section == .columns && !context.isCreatingTable ? reorder.unavailableReason : nil
        )
        configuration.commands = commands(reorderAvailable: reorder.isAvailable)
        return configuration
    }

    private func commands(reorderAvailable: Bool) -> Set<DataGridCommand> {
        // Hide Column and Show All Columns bring back the fields a section starts with hidden.
        var commands: Set<DataGridCommand> = [.valueFilter, .hideColumns]
        guard canEdit else { return commands }
        if canAdd {
            commands.formUnion([.addRow, .duplicateRows, .pasteRows])
        }
        if canRemove {
            commands.formUnion([.deleteRows, .undoDelete])
        }
        if reorderAvailable {
            commands.insert(.moveRows)
        }
        return commands
    }

    private func lockedColumns(provider: StructureRowProvider) -> Set<String> {
        let headings = provider.columns
        return Set(lockedFieldIndices.compactMap { headings.indices.contains($0) ? headings[$0] : nil })
    }

    // MARK: - Menus

    func menuOptions(sourceIndex: Int, field: Int) -> [GridMenuOption]? {
        switch section {
        case .indexes:
            guard manager.workingIndexes.indices.contains(sourceIndex) else { return nil }
            return StructureRowProvider.indexMenuOptions(
                columnIndex: field,
                index: manager.workingIndexes[sourceIndex],
                serverSupport: serverSupport
            )
        case .foreignKeys:
            guard context.allows(.addForeignKey), manager.workingForeignKeys.indices.contains(sourceIndex) else { return nil }
            referenceMenus.origin = context.scope
            return referenceMenus.options(
                columnIndex: field,
                foreignKey: manager.workingForeignKeys[sourceIndex],
                tableColumns: manager.workingColumns.map(\.name)
            )
        case .columns:
            guard manager.workingColumns.indices.contains(sourceIndex),
                  provider.orderedColumnFields.indices.contains(field) else { return nil }
            return ColumnCharacterSetMenus.options(
                for: provider.orderedColumnFields[field],
                column: manager.workingColumns[sourceIndex],
                context: characterSetContext
            )
        case .checkConstraints:
            return nil
        }
    }

    // Read-only per row, which the column-wide lock cannot say: a type with no character set, or a catalog not read.
    func characterSetLockedFields(sourceIndex: Int) -> Set<Int> {
        guard section == .columns, manager.workingColumns.indices.contains(sourceIndex) else { return [] }
        return ColumnCharacterSetMenus.lockedFieldIndices(
            orderedFields: provider.orderedColumnFields,
            column: manager.workingColumns[sourceIndex],
            catalog: characterSetContext.catalog
        )
    }

    // Opening the menu is the retry, as it is for the reference menus.
    func readCharacterSetCatalogIfNeeded(field: Int) {
        guard section == .columns, provider.orderedColumnFields.indices.contains(field),
              ColumnCharacterSetMenus.isCharacterSetField(provider.orderedColumnFields[field]) else { return }
        editor?.readCharacterSetCatalogIfNeeded()
    }

    // MARK: - Edits

    @discardableResult
    func applyEdit(rowID: RowID, field: Int, text: String) -> Bool {
        guard canEdit, let sourceIndex = sourceIndex(of: rowID) else { return false }
        let applied = write(text, field: field, sourceIndex: sourceIndex)
        editor?.definitionsDidChange()
        return applied
    }

    @discardableResult
    func applyEdit(entity id: UUID, field: Int, text: String) -> Bool {
        applyEdit(rowID: rowID(forEntity: id), field: field, text: text)
    }

    private func write(_ text: String, field: Int, sourceIndex: Int) -> Bool {
        let characterSets = characterSetContext
        guard field >= 0,
              !lockedFieldIndices.contains(field),
              !manager.deleteInsertState(for: sourceIndex, tab: section).isDeleted,
              !StructureGridEdits.refuses(
                  text,
                  field: field,
                  sourceIndex: sourceIndex,
                  tab: section,
                  manager: manager,
                  orderedFields: provider.orderedColumnFields,
                  characterSets: characterSets
              ) else { return false }
        let changedReference = StructureGridEdits.apply(
            text,
            field: field,
            sourceIndex: sourceIndex,
            tab: section,
            manager: manager,
            orderedFields: provider.orderedColumnFields,
            connection: context.connection,
            characterSets: characterSets
        )
        if let changedReference {
            referenceMenus.origin = context.scope
            referenceMenus.prefetchReferencedColumns(
                of: changedReference.referencedTable, schema: changedReference.referencedSchema
            )
        }
        return true
    }

    func addRow() {
        guard canEdit, canAdd else { return }
        StructureGridEdits.addRow(on: section, manager: manager)
        editor?.definitionsDidChange()
        if let id = StructureGridEdits.entityIDs(in: section, manager: manager).last {
            editor?.reveal(section: section, entity: id)
        }
    }

    func deleteRows(_ rowIDs: [RowID]) {
        guard canEdit, canRemove, !rowIDs.isEmpty else { return }
        let displayRows = IndexSet(rowIDs.compactMap { model.displayIndex(of: $0) })
        let countBefore = model.rowCount
        StructureGridEdits.delete(sourceIndices: sourceIndices(of: rowIDs), tab: section, manager: manager)
        editor?.definitionsDidChange()
        selectAfterDeleting(displayRows, countBefore: countBefore)
    }

    private func selectAfterDeleting(_ displayRows: IndexSet, countBefore: Int) {
        let remaining = model.rowCount
        guard remaining > 0, let minRow = displayRows.first, let maxRow = displayRows.last else {
            model.clearSelection()
            return
        }
        // Deleting an existing definition keeps its row (struck through); the selection stays on it.
        guard remaining < countBefore else { return }
        let removed = countBefore - remaining
        let target = maxRow - removed + 1 < remaining ? maxRow - removed + 1 : (minRow > 0 ? minRow - 1 : 0)
        guard let rowID = model.rowID(at: min(max(target, 0), remaining - 1)) else {
            model.clearSelection()
            return
        }
        model.selectRows([rowID])
    }

    func duplicateRows(_ rowIDs: [RowID]) {
        guard canEdit, canAdd else { return }
        StructureGridEdits.duplicate(sourceIndices: sourceIndices(of: rowIDs), tab: section, manager: manager)
        editor?.definitionsDidChange()
    }

    func undoDelete(_ rowIDs: [RowID]) {
        let ids = rowIDs.compactMap(entityID(of:))
        manager.performAsOneUndoStep {
            for id in ids {
                manager.undoDelete(section: section, id: id)
            }
        }
        editor?.definitionsDidChange()
    }

    func navigateToForeignKey(sourceIndex: Int) {
        guard manager.workingForeignKeys.indices.contains(sourceIndex), let coordinator else { return }
        let foreignKey = manager.workingForeignKeys[sourceIndex]
        let target = ForeignKeyTargetScope.resolve(
            origin: context.scope, referencedSchema: foreignKey.referencedSchema, databaseType: context.databaseType
        )
        coordinator.openTableTab(foreignKey.referencedTable, schema: target.schema, database: target.database)
    }

    func sortDidChange(_ sort: SortState) {
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

// MARK: - DataGridDataSource

extension StructureSectionAdapter: DataGridDataSource {
    var gridRows: TableRows { snapshot.rows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridVisualState(for rowID: RowID) -> RowVisualState? {
        snapshot.state(for: rowID)
    }

    func gridCheckboxState(for rowID: RowID, column: DataGridColumn) -> Bool? {
        guard provider.booleanColumns.contains(column.dataIndex),
              let row = snapshot.rows.row(withID: rowID), column.dataIndex < row.values.count else { return nil }
        return row.values[column.dataIndex].asText == "YES"
    }

    func gridMenuOptions(for rowID: RowID, column: DataGridColumn) -> [GridMenuOption]? {
        guard let sourceIndex = sourceIndex(of: rowID) else { return nil }
        let options = menuOptions(sourceIndex: sourceIndex, field: column.dataIndex)
        readCharacterSetCatalogIfNeeded(field: column.dataIndex)
        return options
    }
}

// MARK: - DataGridActions

extension StructureSectionAdapter: DataGridActions {
    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        guard canEdit, !edits.isEmpty else { return false }
        var applied = false
        manager.performAsOneUndoStep {
            for edit in edits {
                guard let sourceIndex = sourceIndex(of: edit.rowID) else { continue }
                if write(edit.newValue.asText ?? "", field: edit.dataIndex, sourceIndex: sourceIndex) {
                    applied = true
                }
            }
        }
        editor?.definitionsDidChange()
        return applied
    }

    func gridSetCheckbox(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn) {
        guard canEdit, provider.booleanColumns.contains(column.dataIndex) else { return }
        manager.performAsOneUndoStep {
            for rowID in rowIDs {
                guard let sourceIndex = sourceIndex(of: rowID) else { continue }
                _ = write(isOn ? "YES" : "NO", field: column.dataIndex, sourceIndex: sourceIndex)
            }
        }
        editor?.definitionsDidChange()
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
        canEdit && canAdd && StructurePasteboard.canPaste
    }

    func gridPasteRows() {
        pasteRows()
    }

    func gridCopyRows(_ rowIDs: [RowID]) -> Bool {
        guard !rowIDs.isEmpty else { return false }
        copyRows(rowIDs)
        return true
    }

    // A move is offered only while nothing filters or sorts the list, so the drop index is a working index.
    func gridMoveRow(from source: RowID, toDisplayIndex destination: Int) {
        guard let sourceIndex = sourceIndex(of: source) else { return }
        editor?.moveColumn(from: sourceIndex, to: destination)
    }

    // The provider sorts by one column, so a secondary key the header appended is dropped.
    func gridSortDidChange(_ sort: SortState) {
        sortDidChange(sort)
    }

    // A value filter rearranges the list, which withdraws the column move.
    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        apply()
        model.configuration = makeConfiguration(provider: provider)
    }

    func gridRowMenuItems(for rowIDs: [RowID], clickedRow: RowID) -> [NSMenuItem] {
        rowMenuItems(for: rowIDs, clickedRow: clickedRow)
    }

    func gridEmptySpaceMenu() -> NSMenu? {
        nil
    }
}

// Mints one RowID per definition id and keeps it for the adapter's lifetime.
struct StructureRowIdentities {
    private var rowIDs: [UUID: RowID] = [:]
    private var entityIDs: [RowID: UUID] = [:]
    private var next = 0

    mutating func rowID(for id: UUID) -> RowID {
        if let existing = rowIDs[id] { return existing }
        let rowID = RowID.existing(next)
        next += 1
        rowIDs[id] = rowID
        entityIDs[rowID] = id
        return rowID
    }

    func entityID(of rowID: RowID) -> UUID? {
        entityIDs[rowID]
    }
}
