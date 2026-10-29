//
//  StructureDefinitionEditor.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

// The Definition page's model, shared by the Structure tab and Create Table: one grid per section over one change
// manager, one filter, and what the inspector shows. A row selected in one section clears the others, so the
// inspector always names one thing.
@MainActor
final class StructureDefinitionEditor: ObservableObject {
    enum InspectorTarget: Equatable {
        case table
        case entity(StructureSection, UUID)
        case several(StructureSection, Int)
    }

    let manager: StructureChangeManager
    let context: StructureEditingContext
    let referenceMenus: ForeignKeyReferenceMenus
    private(set) var adapters: [StructureSection: StructureSectionAdapter] = [:]

    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            refresh()
        }
    }
    @Published private(set) var inspectorTarget: InspectorTarget = .table
    @Published private(set) var collapsedSections: Set<StructureSection>
    @Published var serverSupport = StructureServerSupport.unrestricted {
        didSet {
            guard serverSupport != oldValue else { return }
            // A section the server withdraws leaves no selection behind for the inspector or the commands.
            for section in StructureSection.allCases where !offers(section) {
                adapter(for: section).model.clearSelection()
            }
            refresh()
        }
    }
    @Published var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            refresh()
        }
    }
    // After a save, until the table is read again: an edit made now would stage against what the save replaced.
    @Published var isAwaitingBaseline = false {
        didSet {
            guard isAwaitingBaseline != oldValue else { return }
            refresh()
        }
    }
    @Published private(set) var revision = 0

    var readOnlyReason: String?

    weak var coordinator: MainContentCoordinator?
    var moveColumnHandler: ((Int, Int) -> Void)?
    var characterSetContextProvider: () -> ColumnCharacterSetMenus.Context = {
        ColumnCharacterSetMenus.Context(catalog: .idle, tableCharacterSet: nil)
    }
    var characterSetCatalogReader: () -> Void = {}

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var fieldDraft: (text: String, commit: (String) -> Void)? {
        didSet {
            let isPending = fieldDraft != nil
            if hasPendingFieldDraft != isPending { hasPendingFieldDraft = isPending }
        }
    }
    private var isSyncingSelection = false

    init(
        manager: StructureChangeManager,
        context: StructureEditingContext,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        self.manager = manager
        self.context = context
        self.defaults = defaults
        let menus = ForeignKeyReferenceMenus(connectionId: context.connection.id, databaseType: context.databaseType)
        menus.schemaName = context.schemaName
        referenceMenus = menus
        let stored = defaults.stringArray(forKey: Self.collapsedSectionsKey) ?? []
        collapsedSections = Set(stored.compactMap(StructureSection.init(rawValue:)))
        for section in StructureSection.allCases {
            let adapter = StructureSectionAdapter(
                section: section, manager: manager, context: context, referenceMenus: menus, defaults: defaults
            )
            adapters[section] = adapter
            adapter.editor = self
            adapter.model.$selectionRevision
                .dropFirst()
                .sink { [weak self] _ in self?.selectionDidChange(in: section) }
                .store(in: &cancellables)
        }
        menus.onListsChanged = { [weak self] in self?.revision &+= 1 }
        manager.$reloadVersion
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    static let collapsedSectionsKey = "structure.collapsedSections"

    // MARK: - Sections

    var sections: [StructureSection] {
        StructureSection.allCases.filter(offers)
    }

    func offers(_ section: StructureSection) -> Bool {
        switch section {
        case .columns, .indexes:
            return true
        case .foreignKeys:
            return context.databaseType.supportsForeignKeys
        case .checkConstraints:
            guard serverSupport.offers(.checkConstraints) else { return false }
            guard !context.isCreatingTable else { return context.allows(.addCheckConstraint) }
            return context.databaseType.supportsCheckConstraints
        }
    }

    func adapter(for section: StructureSection) -> StructureSectionAdapter {
        guard let adapter = adapters[section] else {
            preconditionFailure("Every section has an adapter")
        }
        return adapter
    }

    func isExpanded(_ section: StructureSection) -> Bool {
        !collapsedSections.contains(section) || !searchText.isEmpty
    }

    func setExpanded(_ section: StructureSection, _ isExpanded: Bool) {
        if isExpanded {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
            adapter(for: section).model.clearSelection()
        }
        defaults.set(collapsedSections.map(\.rawValue).sorted(), forKey: Self.collapsedSectionsKey)
    }

    func count(of section: StructureSection) -> Int {
        let ids = StructureGridEdits.entityIDs(in: section, manager: manager)
        return ids.indices.filter { !manager.deleteInsertState(for: $0, tab: section).isDeleted }.count
    }

    var characterSetContext: ColumnCharacterSetMenus.Context { characterSetContextProvider() }

    func readCharacterSetCatalogIfNeeded() {
        characterSetCatalogReader()
    }

    // MARK: - Refresh

    func refresh() {
        for section in StructureSection.allCases {
            adapter(for: section).refresh()
        }
        settleInspectorTarget()
        revision &+= 1
    }

    func definitionsDidChange() {
        refresh()
    }

    // MARK: - Selection

    var focusedSection: StructureSection? {
        switch inspectorTarget {
        case .table: nil
        case .entity(let section, _), .several(let section, _): section
        }
    }

    var focusedModel: DataGridModel? {
        focusedSection.map { adapter(for: $0).model }
    }

    private func selectionDidChange(in section: StructureSection) {
        guard !isSyncingSelection else { return }
        let model = adapter(for: section).model
        if !model.selection.isEmpty {
            isSyncingSelection = true
            for other in StructureSection.allCases where other != section {
                adapter(for: other).model.clearSelection()
            }
            isSyncingSelection = false
        }
        settleInspectorTarget()
    }

    private func settleInspectorTarget() {
        var target = InspectorTarget.table
        for section in StructureSection.allCases {
            let ids = adapter(for: section).selectedEntityIDs
            guard !ids.isEmpty else { continue }
            target = ids.count == 1 ? .entity(section, ids[0]) : .several(section, ids.count)
            break
        }
        if target != inspectorTarget {
            inspectorTarget = target
        }
    }

    func clearSelection() {
        for section in StructureSection.allCases {
            adapter(for: section).model.clearSelection()
        }
    }

    func reveal(section: StructureSection, entity id: UUID) {
        if collapsedSections.contains(section) {
            setExpanded(section, true)
        }
        adapter(for: section).select(entity: id)
    }

    // MARK: - Commands

    func add(_ section: StructureSection) {
        adapter(for: section).addRow()
    }

    func canAdd(_ section: StructureSection) -> Bool {
        let adapter = adapter(for: section)
        return adapter.canEdit && adapter.canAdd
    }

    func canRemoveSelection(in section: StructureSection) -> Bool {
        let adapter = adapter(for: section)
        return adapter.canEdit && adapter.canRemove && !adapter.model.selection.isEmpty
    }

    func removeSelection(in section: StructureSection) {
        let adapter = adapter(for: section)
        let rowIDs = adapter.model.selection.affectedRows.compactMap { adapter.model.rowID(at: $0) }
        adapter.deleteRows(rowIDs)
    }

    func refusal(adding section: StructureSection) -> String? {
        let adapter = adapter(for: section)
        if let reason = adapter.editRefusal { return reason }
        return context.refusal(context.addOperation(for: section))
    }

    // The section the menu bar's row commands act on: the one holding the selection, else Columns.
    var commandSection: StructureSection { focusedSection ?? .columns }

    func selectedRowIDs(in section: StructureSection) -> [RowID] {
        let model = adapter(for: section).model
        return model.selection.affectedRows.compactMap { model.rowID(at: $0) }
    }

    var canDuplicateSelection: Bool {
        guard let section = focusedSection else { return false }
        return canAdd(section) && !selectedRowIDs(in: section).isEmpty
    }

    func duplicateSelection() {
        guard canDuplicateSelection, let section = focusedSection else { return }
        adapter(for: section).duplicateRows(selectedRowIDs(in: section))
    }

    func copySelection() {
        guard let section = focusedSection else { return }
        let rowIDs = selectedRowIDs(in: section)
        guard !rowIDs.isEmpty else { return }
        adapter(for: section).copyRows(rowIDs)
    }

    var canPaste: Bool {
        canAdd(commandSection) && StructurePasteboard.canPaste
    }

    func paste() {
        guard canPaste else { return }
        adapter(for: commandSection).pasteRows()
    }

    func moveColumn(from sourceIndex: Int, to destination: Int) {
        moveColumnHandler?(sourceIndex, destination)
    }

    // MARK: - Pending edits

    // An inspector field's typed text is committed on Return or when focus leaves; until then it is noted here, so
    // Save, close and the other commands see it and commit it first.
    @Published private(set) var hasPendingFieldDraft = false

    func noteFieldDraft(_ text: String, commit: @escaping (String) -> Void) {
        fieldDraft = (text, commit)
    }

    func clearFieldDraft() {
        fieldDraft = nil
    }

    func commitPendingEdits() {
        if let draft = fieldDraft {
            fieldDraft = nil
            draft.commit(draft.text)
        }
        for section in StructureSection.allCases {
            adapter(for: section).model.commitEditing()
        }
    }

    // MARK: - Inspector

    func entity(_ section: StructureSection, id: UUID) -> Int? {
        StructureGridEdits.sourceIndex(of: id, in: section, manager: manager)
    }

    func inspectorForm(for section: StructureSection, id: UUID) -> StructureInspectorForm? {
        let adapter = adapter(for: section)
        guard let sourceIndex = entity(section, id: id) else { return nil }
        return StructureInspectorForm.build(adapter: adapter, sourceIndex: sourceIndex, entityID: id)
    }

    func commitInspectorField(section: StructureSection, id: UUID, field: Int, value: String) {
        adapter(for: section).applyEdit(entity: id, field: field, text: value)
    }
}
