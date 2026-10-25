import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct CompareRowGridModelTests {
    private let suite: EphemeralDefaults
    private let columns = ["id", "email", "name"]

    init() throws {
        suite = try EphemeralDefaults()
    }

    @Test func testInsertAndIdenticalGiveOneSourceLineThatOpensTheEntry() {
        for kind in [RowDiffKind.insert, .identical] {
            let diff = entry(kind, key: "k1")

            let lines = CompareRowGridModel.lines(for: diff)

            #expect(lines.count == 1, "\(kind)")
            #expect(lines.first?.side == .source, "\(kind)")
            #expect(lines.first?.opensEntry == true, "\(kind)")
            #expect(lines.first?.entry.id == diff.id, "\(kind)")
        }
    }

    @Test func testDeleteGivesOneTargetLineThatOpensTheEntry() {
        let diff = entry(.delete, key: "k1")

        let lines = CompareRowGridModel.lines(for: diff)

        #expect(lines.count == 1)
        #expect(lines.first?.side == .target)
        #expect(lines.first?.opensEntry == true)
        #expect(lines.first?.entry.id == diff.id)
    }

    @Test func testUpdateAndConflictGiveSourceThenTargetWithOnlyTheFirstOpeningTheEntry() {
        for kind in [RowDiffKind.update, .conflict] {
            let diff = entry(kind, key: "k1", differingIn: ["email"])

            let lines = CompareRowGridModel.lines(for: diff)

            #expect(lines.map(\.side) == [ComparisonSide.source, .target], "\(kind)")
            #expect(lines.map(\.opensEntry) == [true, false], "\(kind)")
            #expect(lines.map(\.entry.id) == [diff.id, diff.id], "\(kind)")
        }
    }

    @Test func testAnInsertLineIsMarkedInsertedInComparisonWords() throws {
        let line = try #require(CompareRowGridModel.lines(for: entry(.insert, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        #expect(state.isInserted)
        #expect(!state.isDeleted)
        #expect(state.modifiedColumns.isEmpty)
        #expect(state.struckColumns.isEmpty)
        #expect(state.vocabulary == .comparison)
    }

    @Test func testADeleteLineIsMarkedDeletedInComparisonWords() throws {
        let line = try #require(CompareRowGridModel.lines(for: entry(.delete, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        #expect(state.isDeleted)
        #expect(!state.isInserted)
        #expect(state.modifiedColumns.isEmpty)
        #expect(state.struckColumns.isEmpty)
        #expect(state.vocabulary == .comparison)
    }

    // Include, Change and Side lead the plan's columns, so `email` at plan index 1 is grid column 4.
    @Test func testAnUpdateMarksTheSourceModifiedAndTheTargetStruckAtTheDifferingGridColumn() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["email"]))
        let expectedColumn = 1 + CompareRowGridModel.leadingColumnCount

        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)
        let target = CompareRowGridModel.visualState(for: lines[1], columns: columns)

        #expect(source.modifiedColumns == [expectedColumn])
        #expect(source.struckColumns.isEmpty)
        #expect(target.struckColumns == [expectedColumn])
        #expect(target.modifiedColumns.isEmpty)
        for state in [source, target] {
            #expect(!state.isInserted)
            #expect(!state.isDeleted)
            #expect(state.vocabulary == .comparison)
        }
    }

    @Test func testADifferingColumnIsFoundWhateverItsCase() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["EMAIL", "Name"]))

        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)

        #expect(source.modifiedColumns == [4, 5])
    }

    @Test func testAnIdenticalLineCarriesNoMark() throws {
        let line = try #require(CompareRowGridModel.lines(for: entry(.identical, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        #expect(!state.isInserted)
        #expect(!state.isDeleted)
        #expect(state.modifiedColumns.isEmpty)
        #expect(state.struckColumns.isEmpty)
        #expect(state.vocabulary == .comparison)
    }

    @Test func testEnsureLoadedLeadsWithIncludeChangeAndSideThenThePlanColumns() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.delete, key: "k3")
        ]

        let rows = model.ensureLoaded(key: key(entryCount: 3), plan: plan(), entries: entries, session: session)

        #expect(rows.columns == ["Include", "Change", "Side", "id", "email", "name"])
        #expect(rows.columnTypes.count == 6)
        #expect(rows.count == 4)
        #expect(rows.count == model.lines.count)
    }

    @Test func testEnsureLoadedFillsEachLineFromItsOwnSide() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.delete, key: "k3")
        ]

        let rows = model.ensureLoaded(key: key(entryCount: 3), plan: plan(), entries: entries, session: session)

        #expect(rows.rows.map(\.id) == [.existing(0), .existing(1), .existing(2), .existing(3)])
        #expect(rows.rows[0][0] == .null)
        #expect(rows.rows[0][1] == .text("Insert"))
        #expect(rows.rows[0][2] == .text("Source"))
        #expect(rows.rows[0][4] == .text("k1@source"))
        #expect(rows.rows[1][1] == .text("Update"))
        #expect(rows.rows[1][4] == .text("k2@source"))
        #expect(rows.rows[2][2] == .text("Target"))
        #expect(rows.rows[2][4] == .text("k2@target"))
        #expect(rows.rows[3][1] == .text("Delete"))
        #expect(rows.rows[3][2] == .text("Target"))
        #expect(rows.rows[3][4] == .text("k3@target"))
    }

    @Test func testEnsureLoadedDoesNotRebuildForTheSameKey() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let sameKey = key(entryCount: 1)
        _ = model.ensureLoaded(key: sameKey, plan: plan(), entries: [entry(.insert, key: "k1")], session: session)

        let again = model.ensureLoaded(
            key: sameKey,
            plan: plan(),
            entries: [entry(.insert, key: "k1"), entry(.update, key: "k2", differingIn: ["email"])],
            session: session
        )

        #expect(again.count == 1)
        #expect(model.lines.count == 1)
    }

    @Test func testEnsureLoadedRebuildsForADifferentKey() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        _ = model.ensureLoaded(
            key: key(entryCount: 1), plan: plan(), entries: [entry(.insert, key: "k1")], session: session
        )

        let rebuilt = model.ensureLoaded(
            key: key(entryCount: 2),
            plan: plan(),
            entries: [entry(.insert, key: "k1"), entry(.update, key: "k2", differingIn: ["email"])],
            session: session
        )

        #expect(rebuilt.count == 3)
        #expect(model.lines.count == 3)
    }

    @Test func testTheGridIsHandedEachLinesVisualState() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [entry(.insert, key: "k1"), entry(.update, key: "k2", differingIn: ["email"])]
        _ = model.ensureLoaded(key: key(entryCount: 2), plan: plan(), entries: entries, session: session)

        #expect(visualState(model, row: 0)?.isInserted == true)
        #expect(visualState(model, row: 1)?.modifiedColumns == Set([4]))
        #expect(visualState(model, row: 2)?.struckColumns == Set([4]))
        #expect(visualState(model, row: 3) == nil)
        #expect(model.grid.gridVisualState(for: .existing(-1)) == nil)
    }

    @Test func testTheIncludeCheckboxShowsOnlyOnTheOpeningLineOfADifference() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        #expect(includeState(model, row: 0) == true)
        #expect(includeState(model, row: 1) == true)
        #expect(includeState(model, row: 2) == nil, "the target line of an update")
        #expect(includeState(model, row: 3) == nil, "an identical row")
        #expect(includeState(model, row: 4) == nil, "a conflict row")
        #expect(includeState(model, row: 5) == nil, "the target line of a conflict")
    }

    @Test func testTheIncludeCheckboxLivesInTheIncludeColumnAlone() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        #expect(checkboxState(model, row: 0, column: 1) == nil)
        #expect(checkboxState(model, row: 0, column: 4) == nil)
        #expect(includeState(model, row: 99) == nil)
        #expect(model.model.configuration.checkboxColumns == [CompareRowGridModel.includeColumn])
    }

    @Test func testTheIncludeCheckboxReflectsARowExcludedInTheSession() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        session.setRowsIncluded(false, entries: [model.lines[0].entry], planId: "orders")

        #expect(includeState(model, row: 0) == false)
        #expect(includeState(model, row: 1) == true)
    }

    @Test func testTheIncludeCheckboxHasNoStateOnceTheSessionNoLongerHoldsThePlan() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        session.adoptDataPlans([
            DataComparePlan(
                table: "customers",
                schema: nil,
                columns: columns.map { CompareColumn(name: $0) },
                scope: DataTableScope(keyColumns: ["id"]),
                isEnabled: true
            )
        ])

        #expect(includeState(model, row: 0) == nil)
    }

    @Test func testClearingTheCheckboxExcludesTheEntriesAndTickingItIncludesThemAgain() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        setCheckbox(model, false, rows: [0, 1], column: CompareRowGridModel.includeColumn)

        #expect(session.dataPlans.first?.excludedRowKeys == Set(["k1", "k2"]))
        #expect(includeState(model, row: 0) == false)
        #expect(includeState(model, row: 1) == false)

        setCheckbox(model, true, rows: [0], column: CompareRowGridModel.includeColumn)

        #expect(session.dataPlans.first?.excludedRowKeys == Set(["k2"]))
        #expect(includeState(model, row: 0) == true)
    }

    @Test func testSettingACheckboxOutsideTheIncludeColumnChangesNothing() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        setCheckbox(model, false, rows: [0, 1], column: 1)

        #expect(session.dataPlans.first?.excludedRowKeys == Set<String>())
    }

    @Test func testSettingTheCheckboxOnRowsThatAreNotDifferencesExcludesNothing() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        setCheckbox(model, false, rows: [3, 4, 5], column: CompareRowGridModel.includeColumn)

        #expect(session.dataPlans.first?.excludedRowKeys == Set<String>())
    }

    // D6: a toggle redraws the checkbox cells; a content replace there used to drop the selection.
    @Test func testTogglingTheIncludeCheckboxKeepsTheRowsAndTheSelection() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)
        let grid = model.model
        let first = try #require(grid.rowID(at: 0))
        let second = try #require(grid.rowID(at: 1))
        let selected = [first, second]
        grid.selectRows(selected)
        let selection = grid.selection
        let selectionRevision = grid.selectionRevision
        let displayRevision = grid.displayRevision

        setCheckbox(model, false, rows: [0, 1], column: CompareRowGridModel.includeColumn)

        #expect(session.dataPlans.first?.excludedRowKeys == Set(["k1", "k2"]))
        #expect(grid.selection == selection)
        #expect(grid.selectionRevision == selectionRevision)
        #expect(grid.displayRevision == displayRevision)
        #expect(grid.selectedRowIDs == selected)
    }

    @Test func testANewLoadClearsASelectionMadeAgainstTheOldOne() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)
        let first = try #require(model.model.rowID(at: 0))
        model.model.selectRows([first])

        model.ensureLoaded(
            key: key(entryCount: 1), plan: plan(), entries: [entry(.delete, key: "k9")], session: session
        )

        #expect(model.model.selection.isEmpty)
        #expect(model.model.rowCount == 1)
    }

    @Test func testSpaceOnSelectedLinesTogglesTheirCheckboxesAndKeepsTheSelection() async throws {
        let session = try makeSession()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.identical, key: "k3"),
            entry(.conflict, key: "k4")
        ]
        let window = ThemeTestFixture.host(
            CompareGridHarness(session: session, entries: entries),
            size: NSSize(width: 800, height: 300)
        )
        defer { window.contentView = nil }
        await Self.settle(window)
        let table = try #require(Self.mainTable(in: window.contentView))
        try #require(table.numberOfRows == 6)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let model = try #require(table.controller?.model)
        try #require(model.selection.affectedRows == IndexSet([0, 1]))

        let space = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: KeyCode.space.rawValue
        ))
        table.keyDown(with: space)
        await Self.settle(window)

        #expect(session.dataPlans.first?.excludedRowKeys == Set(["k1", "k2"]))
        #expect(model.selection.affectedRows == IndexSet([0, 1]))
        #expect(table.selectedRowIndexes == IndexSet([0, 1]))
        #expect(table.numberOfRows == 6)
    }

    @Test func testSameListsTheRetainedIdenticalRows() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.same.entries(in: fixture.summary)

        #expect(listed.map(\.id) == [fixture.identical.id])
    }

    @Test func testAllListsTheDifferencesFollowedByTheIdenticalRows() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.all.entries(in: fixture.summary)

        #expect(listed.map(\.id) == [fixture.insert.id, fixture.update.id, fixture.delete.id, fixture.conflict.id, fixture.identical.id])
    }

    @Test func testOutsideFilterListsOnlyTheConflicts() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.conflict.entries(in: fixture.summary)

        #expect(listed.map(\.id) == [fixture.conflict.id])
    }

    @Test func testDifferenceListsInsertsUpdatesAndDeletesButNoConflict() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.difference.entries(in: fixture.summary)

        #expect(listed.map(\.id) == [fixture.insert.id, fixture.update.id, fixture.delete.id])
    }

    @Test func testAStruckColumnIsStruckThroughAndAModifiedColumnIsUnderlined() {
        let struck = comparisonState(struckColumns: [4])
        let modified = comparisonState(modifiedColumns: [4])

        #expect(DataGridCellTextMark.resolve(state: struck, columnIndex: 4) == .struckThrough)
        #expect(DataGridCellTextMark.resolve(state: struck, columnIndex: 5) == nil)
        #expect(DataGridCellTextMark.resolve(state: modified, columnIndex: 4) == .underlined)
        #expect(DataGridCellTextMark.resolve(state: modified, columnIndex: 5) == nil)
    }

    @Test func testAWholeRowOnlyOnOneSideMarksEveryColumn() {
        let inserted = comparisonState(isInserted: true)
        let deleted = comparisonState(isDeleted: true)

        #expect(DataGridCellTextMark.resolve(state: inserted, columnIndex: 5) == .underlined)
        #expect(DataGridCellTextMark.resolve(state: deleted, columnIndex: 5) == .struckThrough)
    }

    @Test func testAComparisonReadsInComparisonWords() {
        let source = comparisonState(modifiedColumns: [4])
        let target = comparisonState(struckColumns: [4])

        #expect(spoken(comparisonState(isInserted: true), at: 3) == "only in the source")
        #expect(spoken(comparisonState(isDeleted: true), at: 3) == "only in the target")
        #expect(spoken(source, at: 4) == "source value, differs")
        #expect(spoken(target, at: 4) == "target value, differs")
        #expect(spoken(source, at: 5) == nil)
        #expect(spoken(target, at: 5) == nil)
    }

    @Test func testAPendingEditReadsInEditingWords() {
        let inserted = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
        let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
        let edited = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [4])

        #expect(spoken(inserted, at: 3) == "new row")
        #expect(spoken(deleted, at: 3) == "marked for deletion")
        #expect(spoken(edited, at: 4) == "edited")
        #expect(spoken(edited, at: 5) == nil)
    }

    @Test func testTheGridLinesOfAnUpdateReadAsSourceAndTargetValuesAtTheDifferingColumn() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["email"]))
        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)
        let target = CompareRowGridModel.visualState(for: lines[1], columns: columns)

        #expect(spoken(source, at: 4) == "source value, differs")
        #expect(spoken(target, at: 4) == "target value, differs")
        #expect(spoken(source, at: 3) == nil)
    }

    @Test func testACheckboxColumnPresentsAsACheckboxWithNoChevron() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .boolean(rawType: "BOOLEAN"),
            isForeignKey: true,
            isDropdown: true,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true,
            isCheckbox: true
        )

        #expect(presentation.kind == .checkbox)
        #expect(presentation.accessory == .none)
    }

    @Test func testTheCheckboxMarkIsCentredInTheCell() {
        let cell = NSRect(x: 100, y: 0, width: 60, height: 24)

        let frame = DataGridCheckboxMark.frame(in: cell)

        #expect(frame == NSRect(x: 122, y: 4, width: 16, height: 16))
        #expect(frame.midX == cell.midX)
        #expect(frame.midY == cell.midY)
    }

    @Test func testTheCheckboxMarkIsEmptyInACellTooSmallForIt() {
        #expect(DataGridCheckboxMark.frame(in: NSRect(x: 0, y: 0, width: 12, height: 24)).isEmpty)
        #expect(DataGridCheckboxMark.frame(in: NSRect(x: 0, y: 0, width: 60, height: 10)).isEmpty)
    }

    @Test func testACheckboxCellCarriesItsMarkAndNoText() {
        let checked = appearance(kind: .checkbox, text: "", placeholder: .null, checkboxMark: .checked)
        let unchecked = appearance(kind: .checkbox, text: "", placeholder: .null, checkboxMark: .unchecked)

        #expect(checked.checkboxMark == .checked)
        #expect(checked.text == "")
        #expect(unchecked.checkboxMark == .unchecked)
        #expect(unchecked.text == "")
    }

    @Test func testATextCellCarriesNoCheckboxMarkEvenWhenHandedOne() {
        let text = appearance(kind: .text, text: "value", placeholder: nil, checkboxMark: .checked)

        #expect(text.checkboxMark == nil)
        #expect(text.text == "value")
    }

    private func makeSession() throws -> CompareSyncSession {
        let session = CompareSyncSession(
            profileStorage: CompareSyncProfileStorage(defaults: suite.defaults),
            connectionsProvider: { [] }
        )
        session.adoptDataPlans([plan()])
        return session
    }

    private func plan() -> DataComparePlan {
        DataComparePlan(
            table: "orders",
            schema: nil,
            columns: columns.map { CompareColumn(name: $0) },
            scope: DataTableScope(keyColumns: ["id"]),
            isEnabled: true
        )
    }

    private func key(entryCount: Int) -> CompareRowGridModel.LoadKey {
        CompareRowGridModel.LoadKey(
            planId: "orders",
            answer: nil,
            columns: columns,
            filter: .all,
            entryCount: entryCount
        )
    }

    // Lines 0 insert, 1 and 2 update, 3 identical, 4 and 5 conflict.
    private func loadedModel(session: CompareSyncSession) -> CompareRowGridModel {
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.identical, key: "k3"),
            entry(.conflict, key: "k4")
        ]
        let rows = model.ensureLoaded(key: key(entryCount: 4), plan: plan(), entries: entries, session: session)
        #expect(rows.count == 6)
        return model
    }

    private func gridColumn(_ model: CompareRowGridModel, dataIndex: Int) -> DataGridColumn? {
        model.model.columns.columns.first { $0.dataIndex == dataIndex }
    }

    private func visualState(_ model: CompareRowGridModel, row: Int) -> RowVisualState? {
        model.model.rowID(at: row).flatMap { model.grid.gridVisualState(for: $0) }
    }

    private func checkboxState(_ model: CompareRowGridModel, row: Int, column dataIndex: Int) -> Bool? {
        guard let rowID = model.model.rowID(at: row), let column = gridColumn(model, dataIndex: dataIndex) else { return nil }
        return model.grid.gridCheckboxState(for: rowID, column: column)
    }

    private func includeState(_ model: CompareRowGridModel, row: Int) -> Bool? {
        checkboxState(model, row: row, column: CompareRowGridModel.includeColumn)
    }

    // The grid's own path: the model hands the selected rows to its actions.
    private func setCheckbox(_ model: CompareRowGridModel, _ isOn: Bool, rows: [Int], column dataIndex: Int) {
        guard let column = gridColumn(model, dataIndex: dataIndex) else {
            Issue.record("No column at data index \(dataIndex)")
            return
        }
        let rowIDs = rows.compactMap { model.model.rowID(at: $0) }
        model.model.actions?.gridSetCheckbox(isOn, rowIDs: rowIDs, column: column)
    }

    // SwiftUI applies a change on a later run-loop turn, so each pass lays out and waits one main-queue turn.
    private static func settle(_ window: NSWindow) async {
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func mainTable(in view: NSView?) -> DataGridTableView? {
        guard let view else { return nil }
        if let table = view as? DataGridTableView, table.paneKind == .main { return table }
        return view.subviews.lazy.compactMap { mainTable(in: $0) }.first
    }

    private func comparisonState(
        isDeleted: Bool = false,
        isInserted: Bool = false,
        modifiedColumns: Set<Int> = [],
        struckColumns: Set<Int> = []
    ) -> RowVisualState {
        RowVisualState(
            isDeleted: isDeleted,
            isInserted: isInserted,
            modifiedColumns: modifiedColumns,
            struckColumns: struckColumns,
            vocabulary: .comparison
        )
    }

    private func spoken(_ state: RowVisualState, at column: Int) -> String? {
        DataGridCellTextMark.accessibilityDescription(state: state, columnIndex: column)
    }

    private func entry(_ kind: RowDiffKind, key: String, differingIn differing: [String] = []) -> RowDiffEntry {
        let source = DataRow(values: ["id": .text(key), "email": .text("\(key)@source"), "name": .text("Ann")])
        let target = DataRow(values: ["id": .text(key), "email": .text("\(key)@target"), "name": .text("Ann")])
        return RowDiffEntry(
            kind: kind,
            keyDescription: "id = \(key)",
            keyIdentity: key,
            sourceRow: kind == .delete ? nil : source,
            targetRow: kind == .insert ? nil : target,
            cellDifferences: differing.map { column in
                CellDifference(
                    column: column,
                    rule: .exactValue,
                    sourceValue: source.value(for: column),
                    targetValue: target.value(for: column)
                )
            }
        )
    }

    private struct SummaryFixture {
        let summary: DataDiffSummary
        let insert: RowDiffEntry
        let update: RowDiffEntry
        let delete: RowDiffEntry
        let conflict: RowDiffEntry
        let identical: RowDiffEntry
    }

    private func summaryFixture() -> SummaryFixture {
        let insert = entry(.insert, key: "k1")
        let update = entry(.update, key: "k2", differingIn: ["email"])
        let delete = entry(.delete, key: "k3")
        let conflict = entry(.conflict, key: "k4")
        let identical = entry(.identical, key: "k5")
        let summary = DataDiffSummary(
            insertCount: 1,
            updateCount: 1,
            deleteCount: 1,
            identicalCount: 1,
            conflictCount: 1,
            skippedNullKeyCount: 0,
            entries: [insert, update, delete, conflict],
            identicalEntries: [identical],
            truncatedEntries: false
        )
        return SummaryFixture(
            summary: summary,
            insert: insert,
            update: update,
            delete: delete,
            conflict: conflict,
            identical: identical
        )
    }

    private func appearance(
        kind: DataGridCellKind,
        text: String,
        placeholder: DataGridCellPlaceholder?,
        checkboxMark: DataGridCheckboxMark?
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: kind,
            content: DataGridCellContent(
                displayText: text,
                rawValue: placeholder == nil ? text : nil,
                placeholder: placeholder
            ),
            state: DataGridCellState(
                visualState: .empty,
                isEditable: false,
                row: 0,
                columnIndex: CompareRowGridModel.includeColumn
            ),
            palette: DataGridCellPalette(
                regularFont: .systemFont(ofSize: 13),
                italicFont: .systemFont(ofSize: 13),
                mediumFont: .systemFont(ofSize: 13, weight: .medium),
                text: .labelColor,
                placeholderText: .secondaryLabelColor,
                booleanTrueText: .labelColor,
                booleanFalseText: .labelColor,
                rowNumberText: .secondaryLabelColor,
                deletedRowText: .systemRed,
                modifiedColumnTint: .systemYellow,
                findMatchTint: .systemOrange
            ),
            nullDisplayString: "NULL",
            onEmphasizedSelection: false,
            checkboxMark: checkboxMark
        )
    }
}

// The plan is read from the session on every render, as the compare window hands the grid the current plan.
private struct CompareGridHarness: View {
    @ObservedObject var session: CompareSyncSession
    let entries: [RowDiffEntry]

    var body: some View {
        if let plan = session.dataPlans.first {
            CompareRowGrid(session: session, plan: plan, filter: .all, entries: entries)
        }
    }
}
