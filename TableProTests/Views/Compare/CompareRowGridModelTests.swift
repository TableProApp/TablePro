//
//  CompareRowGridModelTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import XCTest

@testable import TablePro

@MainActor
final class CompareRowGridModelTests: XCTestCase {
    private let suiteName = "CompareRowGridModelTests"
    private let columns = ["id", "email", "name"]

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testInsertAndIdenticalGiveOneSourceLineThatOpensTheEntry() {
        for kind in [RowDiffKind.insert, .identical] {
            let diff = entry(kind, key: "k1")

            let lines = CompareRowGridModel.lines(for: diff)

            XCTAssertEqual(lines.count, 1, "\(kind)")
            XCTAssertEqual(lines.first?.side, .source, "\(kind)")
            XCTAssertEqual(lines.first?.opensEntry, true, "\(kind)")
            XCTAssertEqual(lines.first?.entry.id, diff.id, "\(kind)")
        }
    }

    func testDeleteGivesOneTargetLineThatOpensTheEntry() {
        let diff = entry(.delete, key: "k1")

        let lines = CompareRowGridModel.lines(for: diff)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.side, .target)
        XCTAssertEqual(lines.first?.opensEntry, true)
        XCTAssertEqual(lines.first?.entry.id, diff.id)
    }

    func testUpdateAndConflictGiveSourceThenTargetWithOnlyTheFirstOpeningTheEntry() {
        for kind in [RowDiffKind.update, .conflict] {
            let diff = entry(kind, key: "k1", differingIn: ["email"])

            let lines = CompareRowGridModel.lines(for: diff)

            XCTAssertEqual(lines.map(\.side), [ComparisonSide.source, .target], "\(kind)")
            XCTAssertEqual(lines.map(\.opensEntry), [true, false], "\(kind)")
            XCTAssertEqual(lines.map(\.entry.id), [diff.id, diff.id], "\(kind)")
        }
    }

    func testAnInsertLineIsMarkedInsertedInComparisonWords() throws {
        let line = try XCTUnwrap(CompareRowGridModel.lines(for: entry(.insert, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        XCTAssertTrue(state.isInserted)
        XCTAssertFalse(state.isDeleted)
        XCTAssertTrue(state.modifiedColumns.isEmpty)
        XCTAssertTrue(state.struckColumns.isEmpty)
        XCTAssertEqual(state.vocabulary, .comparison)
    }

    func testADeleteLineIsMarkedDeletedInComparisonWords() throws {
        let line = try XCTUnwrap(CompareRowGridModel.lines(for: entry(.delete, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        XCTAssertTrue(state.isDeleted)
        XCTAssertFalse(state.isInserted)
        XCTAssertTrue(state.modifiedColumns.isEmpty)
        XCTAssertTrue(state.struckColumns.isEmpty)
        XCTAssertEqual(state.vocabulary, .comparison)
    }

    /// The grid puts Include, Change and Side ahead of the plan's columns, so `email` at plan index 1
    /// is grid column 4.
    func testAnUpdateMarksTheSourceModifiedAndTheTargetStruckAtTheDifferingGridColumn() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["email"]))
        let expectedColumn = 1 + CompareRowGridModel.leadingColumnCount

        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)
        let target = CompareRowGridModel.visualState(for: lines[1], columns: columns)

        XCTAssertEqual(source.modifiedColumns, [expectedColumn])
        XCTAssertTrue(source.struckColumns.isEmpty)
        XCTAssertEqual(target.struckColumns, [expectedColumn])
        XCTAssertTrue(target.modifiedColumns.isEmpty)
        for state in [source, target] {
            XCTAssertFalse(state.isInserted)
            XCTAssertFalse(state.isDeleted)
            XCTAssertEqual(state.vocabulary, .comparison)
        }
    }

    func testADifferingColumnIsFoundWhateverItsCase() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["EMAIL", "Name"]))

        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)

        XCTAssertEqual(source.modifiedColumns, [4, 5])
    }

    func testAnIdenticalLineCarriesNoMark() throws {
        let line = try XCTUnwrap(CompareRowGridModel.lines(for: entry(.identical, key: "k1")).first)

        let state = CompareRowGridModel.visualState(for: line, columns: columns)

        XCTAssertFalse(state.isInserted)
        XCTAssertFalse(state.isDeleted)
        XCTAssertTrue(state.modifiedColumns.isEmpty)
        XCTAssertTrue(state.struckColumns.isEmpty)
        XCTAssertEqual(state.vocabulary, .comparison)
    }

    func testEnsureLoadedLeadsWithIncludeChangeAndSideThenThePlanColumns() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.delete, key: "k3")
        ]

        let rows = model.ensureLoaded(key: key(entryCount: 3), plan: plan(), entries: entries, session: session)

        XCTAssertEqual(rows.columns, ["Include", "Change", "Side", "id", "email", "name"])
        XCTAssertEqual(rows.columnTypes.count, 6)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.count, model.lines.count)
    }

    func testEnsureLoadedFillsEachLineFromItsOwnSide() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.delete, key: "k3")
        ]

        let rows = model.ensureLoaded(key: key(entryCount: 3), plan: plan(), entries: entries, session: session)

        XCTAssertEqual(rows.rows.map(\.id), [.existing(0), .existing(1), .existing(2), .existing(3)])
        XCTAssertEqual(rows.rows[0][0], .null)
        XCTAssertEqual(rows.rows[0][1], .text("Insert"))
        XCTAssertEqual(rows.rows[0][2], .text("Source"))
        XCTAssertEqual(rows.rows[0][4], .text("k1@source"))
        XCTAssertEqual(rows.rows[1][1], .text("Update"))
        XCTAssertEqual(rows.rows[1][4], .text("k2@source"))
        XCTAssertEqual(rows.rows[2][2], .text("Target"))
        XCTAssertEqual(rows.rows[2][4], .text("k2@target"))
        XCTAssertEqual(rows.rows[3][1], .text("Delete"))
        XCTAssertEqual(rows.rows[3][2], .text("Target"))
        XCTAssertEqual(rows.rows[3][4], .text("k3@target"))
    }

    func testEnsureLoadedDoesNotRebuildForTheSameKey() throws {
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

        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(model.lines.count, 1)
    }

    func testEnsureLoadedRebuildsForADifferentKey() throws {
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

        XCTAssertEqual(rebuilt.count, 3)
        XCTAssertEqual(model.lines.count, 3)
    }

    func testTheDelegateHandsBackEachLinesVisualState() throws {
        let session = try makeSession()
        let model = CompareRowGridModel()
        let entries = [entry(.insert, key: "k1"), entry(.update, key: "k2", differingIn: ["email"])]
        _ = model.ensureLoaded(key: key(entryCount: 2), plan: plan(), entries: entries, session: session)

        XCTAssertEqual(model.dataGridVisualState(forRow: 0)?.isInserted, true)
        XCTAssertEqual(model.dataGridVisualState(forRow: 1)?.modifiedColumns, Set([4]))
        XCTAssertEqual(model.dataGridVisualState(forRow: 2)?.struckColumns, Set([4]))
        XCTAssertNil(model.dataGridVisualState(forRow: 3))
        XCTAssertNil(model.dataGridVisualState(forRow: -1))
    }

    func testTheIncludeCheckboxShowsOnlyOnTheOpeningLineOfADifference() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        XCTAssertEqual(includeState(model, row: 0), true)
        XCTAssertEqual(includeState(model, row: 1), true)
        XCTAssertNil(includeState(model, row: 2), "the target line of an update")
        XCTAssertNil(includeState(model, row: 3), "an identical row")
        XCTAssertNil(includeState(model, row: 4), "a conflict row")
        XCTAssertNil(includeState(model, row: 5), "the target line of a conflict")
    }

    func testTheIncludeCheckboxLivesInTheIncludeColumnAlone() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        XCTAssertNil(model.dataGridCheckboxState(row: 0, column: 1))
        XCTAssertNil(model.dataGridCheckboxState(row: 0, column: 4))
        XCTAssertNil(includeState(model, row: 99))
    }

    func testTheIncludeCheckboxReflectsARowExcludedInTheSession() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        session.setRowsIncluded(false, entries: [model.lines[0].entry], planId: "orders")

        XCTAssertEqual(includeState(model, row: 0), false)
        XCTAssertEqual(includeState(model, row: 1), true)
    }

    func testTheIncludeCheckboxHasNoStateOnceTheSessionNoLongerHoldsThePlan() throws {
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

        XCTAssertNil(includeState(model, row: 0))
    }

    func testClearingTheCheckboxExcludesTheEntriesAndTickingItIncludesThemAgain() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        model.dataGridSetCheckbox(false, rows: IndexSet([0, 1]), column: CompareRowGridModel.includeColumn)

        XCTAssertEqual(session.dataPlans.first?.excludedRowKeys, Set(["k1", "k2"]))
        XCTAssertEqual(includeState(model, row: 0), false)
        XCTAssertEqual(includeState(model, row: 1), false)

        model.dataGridSetCheckbox(true, rows: IndexSet(integer: 0), column: CompareRowGridModel.includeColumn)

        XCTAssertEqual(session.dataPlans.first?.excludedRowKeys, Set(["k2"]))
        XCTAssertEqual(includeState(model, row: 0), true)
    }

    func testSettingACheckboxOutsideTheIncludeColumnChangesNothing() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        model.dataGridSetCheckbox(false, rows: IndexSet([0, 1]), column: 1)

        XCTAssertEqual(session.dataPlans.first?.excludedRowKeys, Set<String>())
    }

    func testSettingTheCheckboxOnRowsThatAreNotDifferencesExcludesNothing() throws {
        let session = try makeSession()
        let model = loadedModel(session: session)

        model.dataGridSetCheckbox(false, rows: IndexSet([3, 4, 5]), column: CompareRowGridModel.includeColumn)

        XCTAssertEqual(session.dataPlans.first?.excludedRowKeys, Set<String>())
    }

    func testSameListsTheRetainedIdenticalRows() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.same.entries(in: fixture.summary)

        XCTAssertEqual(listed.map(\.id), [fixture.identical.id])
    }

    func testAllListsTheDifferencesFollowedByTheIdenticalRows() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.all.entries(in: fixture.summary)

        XCTAssertEqual(
            listed.map(\.id),
            [fixture.insert.id, fixture.update.id, fixture.delete.id, fixture.conflict.id, fixture.identical.id]
        )
    }

    func testOutsideFilterListsOnlyTheConflicts() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.conflict.entries(in: fixture.summary)

        XCTAssertEqual(listed.map(\.id), [fixture.conflict.id])
    }

    func testDifferenceListsInsertsUpdatesAndDeletesButNoConflict() {
        let fixture = summaryFixture()

        let listed = RowDiffFilter.difference.entries(in: fixture.summary)

        XCTAssertEqual(listed.map(\.id), [fixture.insert.id, fixture.update.id, fixture.delete.id])
    }

    func testAStruckColumnIsStruckThroughAndAModifiedColumnIsUnderlined() {
        let struck = comparisonState(struckColumns: [4])
        let modified = comparisonState(modifiedColumns: [4])

        XCTAssertEqual(DataGridCellTextMark.resolve(state: struck, columnIndex: 4), .struckThrough)
        XCTAssertNil(DataGridCellTextMark.resolve(state: struck, columnIndex: 5))
        XCTAssertEqual(DataGridCellTextMark.resolve(state: modified, columnIndex: 4), .underlined)
        XCTAssertNil(DataGridCellTextMark.resolve(state: modified, columnIndex: 5))
    }

    func testAWholeRowOnlyOnOneSideMarksEveryColumn() {
        let inserted = comparisonState(isInserted: true)
        let deleted = comparisonState(isDeleted: true)

        XCTAssertEqual(DataGridCellTextMark.resolve(state: inserted, columnIndex: 5), .underlined)
        XCTAssertEqual(DataGridCellTextMark.resolve(state: deleted, columnIndex: 5), .struckThrough)
    }

    func testAComparisonReadsInComparisonWords() {
        let source = comparisonState(modifiedColumns: [4])
        let target = comparisonState(struckColumns: [4])

        XCTAssertEqual(spoken(comparisonState(isInserted: true), at: 3), "only in the source")
        XCTAssertEqual(spoken(comparisonState(isDeleted: true), at: 3), "only in the target")
        XCTAssertEqual(spoken(source, at: 4), "source value, differs")
        XCTAssertEqual(spoken(target, at: 4), "target value, differs")
        XCTAssertNil(spoken(source, at: 5))
        XCTAssertNil(spoken(target, at: 5))
    }

    func testAPendingEditReadsInEditingWords() {
        let inserted = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
        let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
        let edited = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [4])

        XCTAssertEqual(spoken(inserted, at: 3), "new row")
        XCTAssertEqual(spoken(deleted, at: 3), "marked for deletion")
        XCTAssertEqual(spoken(edited, at: 4), "edited")
        XCTAssertNil(spoken(edited, at: 5))
    }

    func testTheGridLinesOfAnUpdateReadAsSourceAndTargetValuesAtTheDifferingColumn() {
        let lines = CompareRowGridModel.lines(for: entry(.update, key: "k1", differingIn: ["email"]))
        let source = CompareRowGridModel.visualState(for: lines[0], columns: columns)
        let target = CompareRowGridModel.visualState(for: lines[1], columns: columns)

        XCTAssertEqual(spoken(source, at: 4), "source value, differs")
        XCTAssertEqual(spoken(target, at: 4), "target value, differs")
        XCTAssertNil(spoken(source, at: 3))
    }

    func testACheckboxColumnPresentsAsACheckboxWithNoChevron() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .boolean(rawType: "BOOLEAN"),
            isForeignKey: true,
            isDropdown: true,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true,
            isCheckbox: true
        )

        XCTAssertEqual(presentation.kind, .checkbox)
        XCTAssertEqual(presentation.accessory, .none)
    }

    func testTheCheckboxMarkIsCentredInTheCell() {
        let cell = NSRect(x: 100, y: 0, width: 60, height: 24)

        let frame = DataGridCheckboxMark.frame(in: cell)

        XCTAssertEqual(frame, NSRect(x: 122, y: 4, width: 16, height: 16))
        XCTAssertEqual(frame.midX, cell.midX)
        XCTAssertEqual(frame.midY, cell.midY)
    }

    func testTheCheckboxMarkIsEmptyInACellTooSmallForIt() {
        XCTAssertTrue(DataGridCheckboxMark.frame(in: NSRect(x: 0, y: 0, width: 12, height: 24)).isEmpty)
        XCTAssertTrue(DataGridCheckboxMark.frame(in: NSRect(x: 0, y: 0, width: 60, height: 10)).isEmpty)
    }

    func testACheckboxCellCarriesItsMarkAndNoText() {
        let checked = appearance(kind: .checkbox, text: "", placeholder: .null, checkboxMark: .checked)
        let unchecked = appearance(kind: .checkbox, text: "", placeholder: .null, checkboxMark: .unchecked)

        XCTAssertEqual(checked.checkboxMark, .checked)
        XCTAssertEqual(checked.text, "")
        XCTAssertEqual(unchecked.checkboxMark, .unchecked)
        XCTAssertEqual(unchecked.text, "")
    }

    func testATextCellCarriesNoCheckboxMarkEvenWhenHandedOne() {
        let text = appearance(kind: .text, text: "value", placeholder: nil, checkboxMark: .checked)

        XCTAssertNil(text.checkboxMark)
        XCTAssertEqual(text.text, "value")
    }

    private func makeSession() throws -> CompareSyncSession {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let session = CompareSyncSession(
            profileStorage: CompareSyncProfileStorage(defaults: defaults),
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

    /// Lines 0 insert, 1 and 2 update, 3 identical, 4 and 5 conflict.
    private func loadedModel(session: CompareSyncSession) -> CompareRowGridModel {
        let model = CompareRowGridModel()
        let entries = [
            entry(.insert, key: "k1"),
            entry(.update, key: "k2", differingIn: ["email"]),
            entry(.identical, key: "k3"),
            entry(.conflict, key: "k4")
        ]
        let rows = model.ensureLoaded(key: key(entryCount: 4), plan: plan(), entries: entries, session: session)
        XCTAssertEqual(rows.count, 6)
        return model
    }

    private func includeState(_ model: CompareRowGridModel, row: Int) -> Bool? {
        model.dataGridCheckboxState(row: row, column: CompareRowGridModel.includeColumn)
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
                isFocused: false,
                isEditable: false,
                isLargeDataset: false,
                row: 0,
                columnIndex: CompareRowGridModel.includeColumn
            ),
            palette: DataGridCellPalette(
                regularFont: .systemFont(ofSize: 13),
                italicFont: .systemFont(ofSize: 13),
                mediumFont: .systemFont(ofSize: 13, weight: .medium),
                text: .labelColor,
                placeholderText: .secondaryLabelColor,
                booleanTrueText: nil,
                booleanFalseText: nil,
                rowNumberText: .secondaryLabelColor,
                deletedRowText: .systemRed,
                modifiedColumnTint: .systemYellow,
                findMatchTint: .systemOrange
            ),
            nullDisplayString: "NULL",
            onEmphasizedSelection: false,
            hasOverlay: false,
            checkboxMark: checkboxMark
        )
    }
}
