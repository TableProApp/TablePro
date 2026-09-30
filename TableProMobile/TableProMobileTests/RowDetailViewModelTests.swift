import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@MainActor
@Suite("RowDetailViewModel")
struct RowDetailViewModelTests {
    private func makeColumns() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
    }

    private func makeRows() -> [Row] {
        [
            Row(cells: [.text("1"), .text("Alice")]),
            Row(cells: [.text("2"), .text("Bob")])
        ]
    }

    private func makeSession(driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "test")
    }

    @Test("canEdit requires session, table, primary key, and not safe-mode-blocked")
    func canEditPreconditions() {
        let driver = MockDatabaseDriver()

        let withoutTable = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        #expect(withoutTable.canEdit == false, "no table → cannot edit")

        let blocked = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { .readOnly }
        )
        #expect(blocked.canEdit == false, "read-only safe mode → cannot edit")

        let editable = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { .off }
        )
        #expect(editable.canEdit == true)
    }

    @Test("startEditing populates editedValues from current row")
    func startEditingCopiesValues() {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )

        vm.startEditing()
        #expect(vm.isEditing == true)
        #expect(vm.editedValues == ["1", "Alice"])
    }

    @Test("cancelEditing clears edited values")
    func cancelEditingResets() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        vm.cancelEditing()
        #expect(vm.isEditing == false)
        #expect(vm.editedValues.isEmpty)
    }

    @Test("toggleNull flips between empty string and nil")
    func toggleNullFlips() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        vm.startEditing()

        #expect(vm.editedValues[1] == "Alice")
        vm.toggleNull(at: 1)
        #expect(vm.editedValues[1] == nil)

        vm.toggleNull(at: 1)
        #expect(vm.editedValues[1] == "")
    }

    @Test("saveChanges with no changes early-returns true and exits edit mode")
    func saveNoChanges() async {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(vm.isEditing == false)
        #expect(driver.executedQueries.isEmpty, "no UPDATE should be issued when nothing changed")
    }

    @Test("saveChanges runs UPDATE with primary keys and modified columns only")
    func saveExecutesUpdate() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(driver.executedQueries.count == 1)
        let query = driver.executedQueries[0].uppercased()
        #expect(query.hasPrefix("UPDATE"))
        #expect(query.contains("WHERE"))
    }

    @Test("A column the server owns is not offered for editing and is never written")
    func serverOwnedColumnsTakeNoEdits() async {
        let columns = [
            ColumnInfo(name: "code", typeName: "VARCHAR(8)", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(
                name: "ID", typeName: "INT", isNullable: false, ordinalPosition: 1,
                isAutoIncrement: true, rejectsWrittenValues: true
            ),
            ColumnInfo(name: "doubled", typeName: "INT", ordinalPosition: 2, isGenerated: true),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 3)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("a"), .text("1761"), .text("3522"), .text("Alice")])],
            initialIndex: 0,
            table: TableInfo(name: "approved"),
            session: makeSession(driver: driver),
            columnDetails: columns
        )

        #expect(vm.takesEdits(at: 1) == false)
        #expect(vm.takesEdits(at: 2) == false)
        #expect(vm.takesEdits(at: 3) == true)

        vm.startEditing()
        vm.setEditedValue("1890", at: 1)
        vm.setEditedValue("0", at: 2)
        vm.setEditedValue("Bea", at: 3)
        let success = await vm.saveChanges()

        #expect(success == true)
        let query = driver.executedQueries.first ?? ""
        #expect(query.contains("Bea"))
        #expect(!query.contains("1890"))
        #expect(!query.contains("doubled"))
    }

    @Test("saveChanges on an idle session opens a read-write transaction and commits it")
    func saveWrapsIdleSession() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(driver.beganTransactionModes == [.readWrite])
        #expect(driver.didCommitTransaction)
        #expect(driver.executedQueries.count == 1)
    }

    @Test("a failed save rolls the transaction back and reports the error")
    func failedSaveRollsBack() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == false)
        #expect(driver.didRollbackTransaction)
        #expect(!driver.didCommitTransaction)
        #expect(vm.operationError != nil)
    }

    @Test("saveChanges joins a transaction the session already holds")
    func saveJoinsOpenTransaction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .explicitTransaction
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(!driver.didBeginTransaction)
        #expect(!driver.didCommitTransaction)
        #expect(driver.executedQueries.count == 1)
    }

    @Test("saveChanges under confirmWrites defers execution and requests confirmation")
    func saveConfirmWritesDefers() async {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { .confirmWrites }
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == false)
        #expect(vm.pendingWriteConfirmation == true)
        #expect(vm.isEditing == true, "stays in edit mode until confirmed")
        #expect(driver.executedQueries.isEmpty, "no UPDATE runs before confirmation")
    }

    @Test("executePendingSave runs the deferred UPDATE after confirmation")
    func executePendingSaveRunsUpdate() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { .confirmWrites }
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)
        _ = await vm.saveChanges()

        let success = await vm.executePendingSave()
        #expect(success == true)
        #expect(vm.pendingWriteConfirmation == false)
        #expect(driver.executedQueries.count == 1)
        #expect(driver.executedQueries[0].uppercased().hasPrefix("UPDATE"))
    }

    @Test("saveChanges under readOnly never executes")
    func saveReadOnlyBlocks() async {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { .readOnly }
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == false)
        #expect(vm.pendingWriteConfirmation == false)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("saveChanges fails when no primary key value present")
    func saveWithoutPrimaryKey() async {
        let driver = MockDatabaseDriver()
        let columnsNoPK: [ColumnInfo] = [
            ColumnInfo(name: "name", typeName: "TEXT", ordinalPosition: 0)
        ]
        let rows = [Row(cells: [.text("Alice")])]
        let vm = RowDetailViewModel(
            columns: columnsNoPK, rows: rows, initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: columnsNoPK
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 0)

        let success = await vm.saveChanges()
        #expect(success == false)
        #expect(vm.operationError != nil)
    }

    @Test("loadFullValue populates override and clears loadingCell")
    func lazyLoadPopulates() async {
        let provider: (CellRef) async throws -> String? = { _ in "the full blob value" }
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"),
            loadFullValue: provider
        )
        let ref = CellRef(table: "users", column: "name", primaryKey: [.init(column: "id", value: "1")])

        await vm.loadFullValue(ref: ref, forRow: 0, cellIndex: 1)
        #expect(vm.loadingCell == nil)
        #expect(vm.hasOverride(forRow: 0, cellIndex: 1) == true)
    }

    @Test("isNullable follows the column metadata so NOT NULL columns are not offered NULL")
    func isNullableFollowsMetadata() {
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), columnDetails: makeColumns()
        )
        #expect(vm.isNullable(at: 0) == false)
        #expect(vm.isNullable(at: 1) == true)
        #expect(vm.isNullable(at: 99) == true)
    }

    @Test("Stepping stops at the first and last row, and the step flags agree")
    func rowStepsClampAtEnds() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)

        #expect(vm.canGoToPreviousRow == false)
        #expect(vm.canGoToNextRow == true)
        vm.goToPreviousRow()
        #expect(vm.currentIndex == 0)

        vm.goToNextRow()
        #expect(vm.currentIndex == 1)
        #expect(vm.canGoToPreviousRow == true)
        #expect(vm.canGoToNextRow == false)
        vm.goToNextRow()
        #expect(vm.currentIndex == 1)

        vm.goToPreviousRow()
        #expect(vm.currentIndex == 0)
    }

    @Test("A row being edited cannot be stepped away from, and the navigator hides until editing ends")
    func editingHoldsTheRow() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        #expect(vm.showsRowNavigator)

        vm.startEditing()
        #expect(vm.showsRowNavigator == false)
        #expect(vm.canGoToPreviousRow == false)
        #expect(vm.canGoToNextRow == false)
        vm.goToNextRow()
        #expect(vm.currentIndex == 0)

        vm.cancelEditing()
        #expect(vm.showsRowNavigator)
        #expect(vm.canGoToNextRow)
    }

    @Test("Only a changed value that Save would write counts as an unsaved edit")
    func unsavedEditsTrackTheSaveDiff() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        #expect(vm.hasUnsavedEdits == false)

        vm.startEditing()
        #expect(vm.hasUnsavedEdits == false)

        vm.setEditedValue("Charlie", at: 1)
        #expect(vm.hasUnsavedEdits)
        vm.setEditedValue("Alice", at: 1)
        #expect(vm.hasUnsavedEdits == false)

        vm.toggleNull(at: 1)
        #expect(vm.hasUnsavedEdits)

        vm.cancelEditing()
        #expect(vm.hasUnsavedEdits == false)
    }

    @Test("An edited primary key is never an unsaved edit")
    func primaryKeyEditIsIgnored() {
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("99", at: 0)

        #expect(vm.hasUnsavedEdits == false)
    }

    @Test("A successful save leaves no unsaved edit behind")
    func savedEditIsClean() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        #expect(await vm.saveChanges())
        #expect(vm.hasUnsavedEdits == false)
    }

    @Test("Safe mode tightened while the row is open stops editing and saving")
    func tightenedSafeModeBlocksWrites() async {
        let driver = MockDatabaseDriver()
        var level = SafeModeLevel.off
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { level }
        )
        #expect(vm.canEdit)
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        level = .readOnly

        #expect(vm.canEdit == false)
        #expect(await vm.saveChanges() == false)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("A save deferred for confirmation does not run once safe mode turns read-only")
    func deferredSaveRespectsTightenedSafeMode() async {
        let driver = MockDatabaseDriver()
        var level = SafeModeLevel.confirmWrites
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: { level }
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)
        _ = await vm.saveChanges()
        #expect(vm.pendingWriteConfirmation)

        level = .readOnly

        #expect(await vm.executePendingSave() == false)
        #expect(driver.executedQueries.isEmpty)
    }

    private func makeColumns(lastTypeName: String) -> [ColumnInfo] {
        makeColumns() + [ColumnInfo(name: "body", typeName: lastTypeName, ordinalPosition: 2)]
    }

    private func bodyRef(id: String) -> CellRef {
        CellRef(table: "users", column: "body", primaryKey: [.init(column: "id", value: id)])
    }

    private func makeViewModel(
        lastCell: Cell,
        lastTypeName: String = "TEXT",
        driver: MockDatabaseDriver = MockDatabaseDriver(),
        loadFullValue: ((CellRef) async throws -> String?)? = nil
    ) -> RowDetailViewModel {
        let columns = makeColumns(lastTypeName: lastTypeName)
        return RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("1"), .text("Alice"), lastCell])],
            initialIndex: 0,
            table: TableInfo(name: "users"),
            session: makeSession(driver: driver),
            columnDetails: columns,
            loadFullValue: loadFullValue
        )
    }

    @Test("Typing into a truncated value's placeholder is not an edit and Save writes nothing")
    func truncatedPlaceholderTakesNoEdit() async {
        let driver = MockDatabaseDriver()
        let vm = makeViewModel(lastCell: .truncatedText(prefix: "abc", totalBytes: 5_000, ref: nil), driver: driver)
        vm.startEditing()
        let placeholder = vm.editedValues[2]

        vm.setEditedValue("abcd", at: 2)
        #expect(vm.editedValues[2] == placeholder)
        #expect(vm.hasUnsavedEdits == false)

        vm.toggleNull(at: 2)
        #expect(vm.editedValues[2] == placeholder)
        #expect(vm.hasUnsavedEdits == false)

        #expect(await vm.saveChanges())
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("Typing into a binary value's placeholder is not an edit and Save writes nothing")
    func binaryPlaceholderTakesNoEdit() async {
        let driver = MockDatabaseDriver()
        let vm = makeViewModel(lastCell: .binary(byteCount: 12, ref: nil), lastTypeName: "BLOB", driver: driver)
        vm.startEditing()
        let placeholder = vm.editedValues[2]

        vm.setEditedValue("[BLOB 13 bytes]", at: 2)
        #expect(vm.editedValues[2] == placeholder)
        #expect(vm.hasUnsavedEdits == false)

        vm.toggleNull(at: 2)
        #expect(vm.editedValues[2] == placeholder)
        #expect(vm.hasUnsavedEdits == false)

        #expect(await vm.saveChanges())
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("Saving another field keeps a truncated value truncated, so a later edit cannot type over it")
    func saveKeepsUnloadedValueTruncated() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = makeViewModel(lastCell: .truncatedText(prefix: "abc", totalBytes: 5_000, ref: nil), driver: driver)
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)
        #expect(await vm.saveChanges())
        #expect(vm.currentRow[1] == "Charlie")

        guard case .truncatedText = vm.cells(at: 0)[2] else {
            Issue.record("the unsaved truncated value became \(vm.cells(at: 0)[2])")
            return
        }
        vm.startEditing()
        vm.setEditedValue("abcd", at: 2)
        #expect(vm.hasUnsavedEdits == false)
    }

    @Test("Only a value the row holds in full can be edited as text, and loading makes long text editable")
    func textEditabilityFollowsWhatTheCellHolds() async {
        let truncated = makeViewModel(
            lastCell: .truncatedText(prefix: "abc", totalBytes: 5_000, ref: bodyRef(id: "1")),
            loadFullValue: { _ in "abc and the rest" }
        )
        #expect(truncated.isEditableAsText(at: 1))
        #expect(truncated.isEditableAsText(at: 2) == false)
        await truncated.loadFullValue(ref: bodyRef(id: "1"), forRow: 0, cellIndex: 2)
        #expect(truncated.isEditableAsText(at: 2))

        let binary = makeViewModel(
            lastCell: .binary(byteCount: 12, ref: bodyRef(id: "1")),
            lastTypeName: "BLOB",
            loadFullValue: { _ in "loaded bytes" }
        )
        #expect(binary.isEditableAsText(at: 2) == false)
        await binary.loadFullValue(ref: bodyRef(id: "1"), forRow: 0, cellIndex: 2)
        #expect(binary.isEditableAsText(at: 2) == false)

        let null = makeViewModel(lastCell: .null)
        #expect(null.isEditableAsText(at: 2))
        #expect(null.isEditableAsText(at: 3) == false)
    }

    @Test("A long text value loaded before editing saves the edited full value")
    func loadedLongTextSavesItsEdit() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = makeViewModel(
            lastCell: .truncatedText(prefix: "abc", totalBytes: 5_000, ref: bodyRef(id: "1")),
            driver: driver,
            loadFullValue: { _ in "abc and the rest" }
        )
        await vm.loadFullValue(ref: bodyRef(id: "1"), forRow: 0, cellIndex: 2)
        vm.startEditing()
        #expect(vm.editedValues[2] == "abc and the rest")

        vm.setEditedValue("abc and the rest, edited", at: 2)
        #expect(await vm.saveChanges())
        #expect(driver.executedQueries.count == 1)
        #expect(driver.executedQueries.first?.contains("abc and the rest, edited") == true)
        #expect(vm.currentRow[2] == "abc and the rest, edited")
    }

    @Test("A full value that arrives while editing becomes the field's value, not an unsaved edit")
    func fullValueLoadedWhileEditingIsNotAnEdit() async {
        let fullValue = String(repeating: "a", count: 5_000)
        let vm = makeViewModel(
            lastCell: .truncatedText(prefix: "aaa", totalBytes: 5_000, ref: bodyRef(id: "1")),
            loadFullValue: { _ in fullValue }
        )
        vm.startEditing()

        await vm.loadFullValue(ref: bodyRef(id: "1"), forRow: 0, cellIndex: 2)
        #expect(vm.editedValues[2] == fullValue)
        #expect(vm.hasUnsavedEdits == false)

        vm.setEditedValue(fullValue + "b", at: 2)
        #expect(vm.hasUnsavedEdits)
    }

    @Test("A full value that arrives after swiping to another row is kept for the row that asked for it")
    func lateFullValueLandsOnItsOwnRow() async {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let columns = makeColumns(lastTypeName: "TEXT")
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [
                Row(cells: [.text("1"), .text("Alice"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: bodyRef(id: "1"))]),
                Row(cells: [.text("2"), .text("Bob"), .truncatedText(prefix: "b", totalBytes: 5_000, ref: bodyRef(id: "2"))])
            ],
            initialIndex: 0,
            table: TableInfo(name: "users"),
            columnDetails: columns,
            loadFullValue: { _ in
                startedContinuation.yield()
                for await _ in release { break }
                return "the first row's body"
            }
        )

        let load = Task { await vm.loadFullValue(ref: bodyRef(id: "1"), forRow: 0, cellIndex: 2) }
        for await _ in started { break }
        vm.goToNextRow()
        releaseContinuation.yield()
        await load.value

        #expect(vm.hasOverride(forRow: 0, cellIndex: 2))
        #expect(vm.hasOverride(forRow: 1, cellIndex: 2) == false)
        #expect(vm.row(at: 0)[2] == "the first row's body")
    }

    @Test("A full value asked for from a row that is not the selected one is kept for that row")
    func fullValueLandsOnTheRowThatAsked() async {
        let columns = makeColumns(lastTypeName: "TEXT")
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [
                Row(cells: [.text("1"), .text("Alice"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: bodyRef(id: "1"))]),
                Row(cells: [.text("2"), .text("Bob"), .truncatedText(prefix: "b", totalBytes: 5_000, ref: bodyRef(id: "2"))])
            ],
            initialIndex: 0,
            table: TableInfo(name: "users"),
            columnDetails: columns,
            loadFullValue: { _ in "the second row's body" }
        )

        await vm.loadFullValue(ref: bodyRef(id: "2"), forRow: 1, cellIndex: 2)

        #expect(vm.hasOverride(forRow: 1, cellIndex: 2))
        #expect(vm.hasOverride(forRow: 0, cellIndex: 2) == false)
        #expect(vm.row(at: 1)[2] == "the second row's body")
        #expect(vm.isEditableAsText(at: 2) == false)
    }
}
