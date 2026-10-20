import Foundation
import TableProAutocomplete
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct QueryCompletionControllerTests {
    private static let connectionId = UUID()
    private let ordersColumns = [
        ColumnInfo(name: "id", typeName: "INTEGER", ordinalPosition: 0),
        ColumnInfo(name: "total", typeName: "REAL", ordinalPosition: 1),
    ]

    private func scope(
        _ type: DatabaseType = .sqlite,
        tables: [String] = ["orders"],
        database: String = "main",
        schema: String = "",
        isRunning: Bool = false,
        sessionID: ObjectIdentifier? = nil
    ) -> QueryCompletionScope {
        QueryCompletionScope(
            connectionId: Self.connectionId,
            sessionID: sessionID,
            database: database,
            schema: schema,
            databaseType: type,
            tables: tables.map { TableInfo(name: $0) },
            isRunning: isRunning
        )
    }

    private func controller(_ scope: QueryCompletionScope, source: ControllerColumnSource) -> QueryCompletionController {
        let controller = QueryCompletionController()
        controller.update(scope: scope, readColumns: source.reader)
        return controller
    }

    private func suggest(_ controller: QueryCompletionController, _ text: String, caret: Int? = nil) async -> [QuerySuggestion] {
        let offset = caret ?? (text as NSString).length
        controller.request(text: text, selection: NSRange(location: offset, length: 0), hasMarkedText: false)
        await controller.settle()
        return controller.suggestions
    }

    private func accept(
        _ label: String,
        in text: String,
        caret: Int? = nil,
        with controller: QueryCompletionController
    ) throws -> QueryCompletionEdit {
        let suggestion = try #require(controller.suggestions.first { $0.label == label })
        let selection = NSRange(location: caret ?? (text as NSString).length, length: 0)
        return try #require(controller.edit(for: suggestion, in: text, selection: selection))
    }

    private func applying(_ edit: QueryCompletionEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }

    @Test("a FROM prefix offers the table and an alias with a dot offers its columns")
    func doneCases() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(), source: source)

        let tables = await suggest(controller, "SELECT * FROM or")
        #expect(tables.first?.label == "orders")
        #expect(tables.first?.kind == .table)

        let columns = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        #expect(columns.map { $0.label } == ["id", "total"])
        #expect(columns.allSatisfy { $0.kind == .column })
    }

    @Test("a string or a comment offers nothing")
    func stringAndCommentAreSilent() async {
        let controller = controller(scope(), source: ControllerColumnSource(["orders": ordersColumns]))

        #expect(await !suggest(controller, "SELECT * FROM or").isEmpty)
        #expect(await suggest(controller, "SELECT * FROM orders WHERE note = 'or").isEmpty)
        #expect(await suggest(controller, "SELECT * FROM orders -- or").isEmpty)
    }

    @Test("Redis completes nothing")
    func redisIsOff() async {
        let controller = controller(scope(.redis), source: ControllerColumnSource([:]))

        #expect(await suggest(controller, "SELECT * FROM or").isEmpty)
    }

    @Test("marked text or a selection offers nothing")
    func markedTextAndSelection() async {
        let controller = controller(scope(), source: ControllerColumnSource([:]))
        let text = "SELECT * FROM or"

        controller.request(text: text, selection: NSRange(location: 16, length: 0), hasMarkedText: true)
        await controller.settle()
        #expect(controller.suggestions.isEmpty)

        controller.request(text: text, selection: NSRange(location: 14, length: 2), hasMarkedText: false)
        await controller.settle()
        #expect(controller.suggestions.isEmpty)
    }

    @Test("an opening bracket is replaced, so the name is never left with a stray bracket")
    func openBracket() async throws {
        let controller = controller(
            scope(.mssql, tables: ["orders", "Order Details"], database: "shop", schema: "dbo"),
            source: ControllerColumnSource([:])
        )
        let text = "SELECT * FROM [ord"

        _ = await suggest(controller, text)
        let bare = try accept("orders", in: text, with: controller)
        #expect(bare == QueryCompletionEdit(range: NSRange(location: 14, length: 4), text: "orders", caret: 20))
        #expect(applying(bare, to: text) == "SELECT * FROM orders")

        _ = await suggest(controller, text)
        let bracketed = try accept("Order Details", in: text, with: controller)
        #expect(applying(bracketed, to: text) == "SELECT * FROM [Order Details]")
        #expect(bracketed.caret == 29)
    }

    @Test("a caret inside a closed bracket pair takes the bare name and moves past the close")
    func closedBracketPair() async throws {
        let controller = controller(
            scope(.mssql, tables: ["orders", "Order Details"], database: "shop", schema: "dbo"),
            source: ControllerColumnSource([:])
        )
        let text = "SELECT * FROM [ord]"

        _ = await suggest(controller, text, caret: 18)
        let edit = try accept("orders", in: text, caret: 18, with: controller)
        #expect(edit == QueryCompletionEdit(range: NSRange(location: 15, length: 3), text: "orders", caret: 22))
        #expect(applying(edit, to: text) == "SELECT * FROM [orders]")

        _ = await suggest(controller, text, caret: 18)
        let spaced = try accept("Order Details", in: text, caret: 18, with: controller)
        #expect(applying(spaced, to: text) == "SELECT * FROM [Order Details]")
    }

    @Test("PostgreSQL quotes a mixed-case table, and inside quotes it takes the name as is")
    func postgreSQLQuoting() async throws {
        let controller = controller(
            scope(.postgresql, tables: ["Orders"], database: "shop", schema: "public"),
            source: ControllerColumnSource([:])
        )

        let bare = "SELECT * FROM Ord"
        _ = await suggest(controller, bare)
        #expect(applying(try accept("Orders", in: bare, with: controller), to: bare) == "SELECT * FROM \"Orders\"")

        let quoted = "SELECT * FROM \"Ord\""
        _ = await suggest(controller, quoted, caret: 18)
        let edit = try accept("Orders", in: quoted, caret: 18, with: controller)
        #expect(edit == QueryCompletionEdit(range: NSRange(location: 15, length: 3), text: "Orders", caret: 22))
        #expect(applying(edit, to: quoted) == "SELECT * FROM \"Orders\"")
    }

    @Test("a keyword is inserted with a trailing space in the case it was typed")
    func keywordSpace() async throws {
        let controller = controller(scope(), source: ControllerColumnSource([:]))

        _ = await suggest(controller, "sel")
        let edit = try accept("select", in: "sel", with: controller)
        #expect(edit == QueryCompletionEdit(range: NSRange(location: 0, length: 3), text: "select ", caret: 7))
    }

    @Test("an accepted name is not offered again until the text moves")
    func noRepeatAfterAccept() async throws {
        let controller = controller(scope(), source: ControllerColumnSource([:]))
        let text = "SELECT * FROM or"

        _ = await suggest(controller, text)
        let edit = try accept("orders", in: text, with: controller)
        #expect(edit.caret == 20)
        #expect(controller.suggestions.isEmpty)

        let accepted = applying(edit, to: text)
        #expect(await suggest(controller, accepted, caret: edit.caret).isEmpty)
        #expect(await !suggest(controller, accepted + " ").isEmpty)
    }

    @Test("an edit for text that has since changed is refused")
    func movedTextGetsNoEdit() async {
        let controller = controller(scope(), source: ControllerColumnSource([:]))

        let suggestions = await suggest(controller, "SELECT * FROM or")
        let first = suggestions.first
        #expect(first != nil)
        if let first {
            #expect(controller.edit(for: first, in: "SELECT * FROM ord", selection: NSRange(location: 17, length: 0)) == nil)
        }
    }

    @Test("an answer for another caret position is refused")
    func movedCaretGetsNoEdit() async throws {
        let controller = controller(scope(), source: ControllerColumnSource([:]))
        let text = "SELECT * FROM or"

        let first = try #require(await suggest(controller, text).first)
        #expect(controller.edit(for: first, in: text, selection: NSRange(location: 15, length: 0)) == nil)
        #expect(controller.edit(for: first, in: text, selection: NSRange(location: 16, length: 0)) != nil)
    }

    @Test("a caret inside a quoted name with a space takes the whole name")
    func quotedNameWithSpace() async throws {
        let controller = controller(
            scope(.postgresql, tables: ["Order Details", "orders"], database: "shop", schema: "public"),
            source: ControllerColumnSource([:])
        )
        let text = "SELECT * FROM \"Order Details\""

        _ = await suggest(controller, text, caret: 18)
        let edit = try accept("Order Details", in: text, caret: 18, with: controller)
        #expect(edit == QueryCompletionEdit(range: NSRange(location: 15, length: 13), text: "Order Details", caret: 29))
        #expect(applying(edit, to: text) == text)

        let partial = "SELECT * FROM \"Order Det\""
        _ = await suggest(controller, partial, caret: 18)
        let completed = try accept("Order Details", in: partial, caret: 18, with: controller)
        #expect(applying(completed, to: partial) == "SELECT * FROM \"Order Details\"")
    }

    @Test("a bracketed name typed with a space is replaced from its opening bracket")
    func bracketedNameWithSpace() async throws {
        let controller = controller(
            scope(.mssql, tables: ["Order Details"], database: "shop", schema: "dbo"),
            source: ControllerColumnSource([:])
        )

        let closed = "SELECT * FROM [Order Det]"
        _ = await suggest(controller, closed, caret: 24)
        let inside = try accept("Order Details", in: closed, caret: 24, with: controller)
        #expect(applying(inside, to: closed) == "SELECT * FROM [Order Details]")
        #expect(inside.caret == 29)

        let open = "SELECT * FROM [Order Det"
        _ = await suggest(controller, open)
        #expect(applying(try accept("Order Details", in: open, with: controller), to: open) == "SELECT * FROM [Order Details]")
    }

    @Test("a typed quote whose close belongs to later text leaves that text alone")
    func laterCloseIsNotTheName() async throws {
        let controller = controller(
            scope(.postgresql, tables: ["Orders"], database: "shop", schema: "public"),
            source: ControllerColumnSource([:])
        )
        let text = "SELECT * FROM \"Ord WHERE \"status\" = 1"

        _ = await suggest(controller, text, caret: 18)
        let edit = try accept("Orders", in: text, caret: 18, with: controller)
        #expect(applying(edit, to: text) == "SELECT * FROM \"Orders\" WHERE \"status\" = 1")
    }

    @Test("a qualified column replaces the quotes typed around its name")
    func qualifiedColumnInQuotes() async throws {
        let source = ControllerColumnSource(["orders": ordersColumns, "customers": [ColumnInfo(name: "name", typeName: "TEXT")]])
        let controller = controller(scope(tables: ["orders", "customers"]), source: source)
        let text = "SELECT \"to\" FROM orders o, customers c"

        _ = await suggest(controller, text, caret: 10)
        let edit = try accept("o.total", in: text, caret: 10, with: controller)
        #expect(applying(edit, to: text) == "SELECT o.total FROM orders o, customers c")
        #expect(edit.caret == 14)
    }

    @Test("hiding keeps the bar empty until the caret moves")
    func hideUntilMoved() async {
        let controller = controller(scope(), source: ControllerColumnSource([:]))
        let text = "SELECT * FROM or"

        #expect(await !suggest(controller, text).isEmpty)
        controller.hide()
        #expect(controller.suggestions.isEmpty)
        #expect(await suggest(controller, text).isEmpty)
        #expect(await !suggest(controller, text, caret: 15).isEmpty)
    }

    @Test("WHERE with nothing typed still fills the bar")
    func emptyWhere() async {
        let controller = controller(scope(), source: ControllerColumnSource(["orders": ordersColumns]))

        #expect(await !suggest(controller, "SELECT * FROM orders o WHERE ").isEmpty)
    }

    @Test("UPDATE with nothing typed leads with tables")
    func emptyUpdate() async {
        let controller = controller(scope(), source: ControllerColumnSource([:]))

        let suggestions = await suggest(controller, "UPDATE ")
        #expect(suggestions.first?.label == "orders")
        #expect(suggestions.first?.kind == .table)
    }

    @Test("requests made in one turn run once, on the newest text")
    func requestsCoalesce() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(), source: source)

        controller.request(text: "SELECT o. FROM orders o", selection: NSRange(location: 9, length: 0), hasMarkedText: false)
        controller.request(text: "SELECT * FROM or", selection: NSRange(location: 16, length: 0), hasMarkedText: false)
        await controller.settle()

        #expect(await source.reads.isEmpty)
        #expect(controller.suggestions.first?.label == "orders")
    }

    @Test("an answer that lands after a newer request is dropped")
    func lateAnswerIsDropped() async {
        let source = ControllerColumnSource(["orders": ordersColumns], held: true)
        let controller = controller(scope(), source: source)

        controller.request(text: "SELECT o. FROM orders o", selection: NSRange(location: 9, length: 0), hasMarkedText: false)
        await source.waitForRead()
        controller.onSuggestionsChange = { suggestions in
            guard suggestions.first?.label == "orders" else { return }
            Task { await source.release() }
        }
        controller.request(text: "SELECT * FROM or", selection: NSRange(location: 16, length: 0), hasMarkedText: false)
        await controller.settle()

        #expect(controller.suggestions.first?.label == "orders")
        #expect(!controller.suggestions.contains { $0.kind == .column })
        #expect(await source.reads == ["orders"])
    }

    @Test("no column is read while a run streams or as it ends, only on the next request")
    func noReadWhileRunning() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(isRunning: true), source: source)

        let during = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        #expect(!during.contains { $0.kind == .column })
        #expect(await source.reads.isEmpty)

        controller.update(scope: scope(isRunning: false), readColumns: source.reader)
        await controller.settle()
        #expect(await source.reads.isEmpty)

        let after = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        #expect(after.map { $0.label } == ["id", "total"])
        #expect(await source.reads == ["orders"])
    }

    @Test("a database switch reads columns again")
    func databaseSwitchReadsAgain() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(.mysql, database: "shop"), source: source)

        _ = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        controller.update(scope: scope(.mysql, database: "archive"), readColumns: source.reader)
        await controller.settle()

        #expect(controller.suggestions.map { $0.label } == ["id", "total"])
        #expect(await source.reads == ["orders", "orders"])
    }

    @Test("a new session reads columns again")
    func newSessionReadsAgain() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let first = NSObject()
        let second = NSObject()
        let controller = controller(scope(sessionID: ObjectIdentifier(first)), source: source)

        _ = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        controller.update(scope: scope(sessionID: ObjectIdentifier(second)), readColumns: source.reader)
        await controller.settle()

        #expect(controller.suggestions.map { $0.label } == ["id", "total"])
        #expect(await source.reads == ["orders", "orders"])
        #expect(first !== second)
    }

    @Test("a run's end reads cached columns again")
    func runEndReadsColumnsAgain() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(), source: source)

        _ = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        await source.setColumns(["orders": ordersColumns + [ColumnInfo(name: "status", typeName: "TEXT", ordinalPosition: 2)]])
        controller.update(scope: scope(isRunning: true), readColumns: source.reader)
        controller.update(scope: scope(isRunning: false), readColumns: source.reader)
        await controller.settle()
        #expect(await source.reads == ["orders"])

        let after = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        #expect(after.map { $0.label } == ["id", "total", "status"])
        #expect(await source.reads == ["orders", "orders"])
    }

    @Test("a new database drops the old suggestions before its own arrive")
    func scopeChangeDropsTheOldAnswer() async throws {
        let controller = controller(scope(database: "shop"), source: ControllerColumnSource([:]))
        let text = "SELECT * FROM or"

        let old = try #require(await suggest(controller, text).first)
        controller.update(scope: scope(tables: ["orders"], database: "archive"), readColumns: ControllerColumnSource([:]).reader)
        #expect(controller.suggestions.isEmpty)
        #expect(controller.edit(for: old, in: text, selection: NSRange(location: 16, length: 0)) == nil)

        await controller.settle()
        #expect(controller.suggestions.first?.label == "orders")
    }

    @Test("a run waits for a column read already sent")
    func runWaitsForSentRead() async {
        let source = ControllerColumnSource(["orders": ordersColumns], held: true)
        let controller = controller(scope(), source: source)

        controller.request(text: "SELECT o. FROM orders o", selection: NSRange(location: 9, length: 0), hasMarkedText: false)
        await source.waitForRead()
        let fence = Task {
            await controller.finishColumnReads()
            return await source.finishedReads
        }
        await source.release()

        #expect(await fence.value == 1)
        await controller.settle()
    }

    @Test("the column reader asks whichever session is current")
    func readerFollowsSession() async throws {
        let first = MockDatabaseDriver()
        first.scriptedColumns = [ColumnInfo(name: "id", typeName: "INTEGER")]
        let second = MockDatabaseDriver()
        second.scriptedColumns = [ColumnInfo(name: "total", typeName: "REAL")]
        let holder = SessionHolder()
        holder.session = ConnectionSession(connectionId: Self.connectionId, driver: first, activeDatabase: "main")
        let reader = QueryCompletionController.columnReader { holder.session }

        let before = try await reader("orders", nil)
        holder.session = ConnectionSession(connectionId: Self.connectionId, driver: second, activeDatabase: "main")
        let after = try await reader("orders", nil)
        holder.session = nil
        let none = try await reader("orders", nil)

        #expect(before?.map { $0.name } == ["id"])
        #expect(after?.map { $0.name } == ["total"])
        #expect(none == nil)
        #expect(first.fetchColumnsCalls == 1)
        #expect(second.fetchColumnsCalls == 1)
    }
}

extension QueryCompletionControllerTests {
    @Test("the session reader reads nothing while the session is busy")
    func sessionReaderWaitsForIdle() async throws {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = [ColumnInfo(name: "id", typeName: "INTEGER")]
        let holder = SessionHolder()
        holder.session = ConnectionSession(connectionId: Self.connectionId, driver: driver, activeDatabase: "main")
        holder.isBusy = true
        let reader = QueryCompletionController.columnReader(session: { holder.session }, isBusy: { holder.isBusy })

        let during = try await reader("orders", nil)
        holder.isBusy = false
        let after = try await reader("orders", nil)

        #expect(during == nil)
        #expect(after?.map { $0.name } == ["id"])
        #expect(driver.fetchColumnsCalls == 1)
    }

    @Test("a new table list reads cached columns again, as DDL or a commit may have changed them")
    func newTableListReadsColumnsAgain() async {
        let source = ControllerColumnSource(["orders": ordersColumns])
        let controller = controller(scope(), source: source)

        _ = await suggest(controller, "SELECT o. FROM orders o", caret: 9)
        controller.update(scope: scope(tables: ["orders", "invoices"]), readColumns: source.reader)
        await controller.settle()
        _ = await suggest(controller, "SELECT o. FROM orders o", caret: 9)

        #expect(await source.reads == ["orders", "orders"])
    }

    @Test("the session table reader reads only while idle, inside the session work it is handed")
    func sessionTableReaderIsTracked() async throws {
        let driver = MockDatabaseDriver()
        driver.scriptedTables = [TableInfo(name: "invoices")]
        let holder = SessionHolder()
        holder.session = ConnectionSession(connectionId: Self.connectionId, driver: driver, activeDatabase: "main")
        holder.isBusy = true
        let reader = QueryCompletionController.tableReader(
            session: { holder.session },
            isBusy: { holder.isBusy },
            tracked: { read in
                holder.trackedReads += 1
                return try await read()
            }
        )

        let whileBusy = try await reader("sales")
        holder.isBusy = false
        let idle = try await reader("sales")

        #expect(whileBusy == nil)
        #expect(idle?.map(\.name) == ["invoices"])
        #expect(holder.trackedReads == 1)
    }
}

@MainActor
private final class SessionHolder {
    var session: ConnectionSession?
    var isBusy = false
    var trackedReads = 0
}

private actor ControllerColumnSource {
    private var columns: [String: [ColumnInfo]]
    private var isHeld: Bool
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads: [String] = []
    private(set) var finishedReads = 0

    init(_ columns: [String: [ColumnInfo]], held: Bool = false) {
        self.columns = columns
        self.isHeld = held
    }

    nonisolated var reader: QueryColumnReader {
        { table, schema in await self.read(table, schema) }
    }

    func waitForRead() async {
        guard reads.isEmpty else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func release() {
        isHeld = false
        heldReads.forEach { $0.resume() }
        heldReads = []
    }

    func setColumns(_ columns: [String: [ColumnInfo]]) {
        self.columns = columns
    }

    private func read(_ table: String, _ schema: String?) async -> [ColumnInfo]? {
        reads.append(table)
        readWaiters.forEach { $0.resume() }
        readWaiters = []
        if isHeld {
            await withCheckedContinuation { heldReads.append($0) }
        }
        finishedReads += 1
        return columns[table] ?? []
    }
}

extension QueryCompletionControllerTests {
    // Ranked on `Det`, `Details` led, and Tab turned `[Order Det]` into `[Details]`.
    @Test("a bracketed name with a space ranks on the whole name")
    func bracketedNameRanksOnTheWholeName() async {
        let controller = controller(
            scope(.mssql, tables: ["Details", "Order Details"], database: "shop", schema: "dbo"),
            source: ControllerColumnSource([:])
        )

        let suggestions = await suggest(controller, "SELECT * FROM [Order Det]", caret: 24)

        #expect(suggestions.first?.label == "Order Details")
    }

    @Test("inside quotes only names are offered")
    func quotesOfferNoKeyword() async {
        let controller = controller(
            scope(.mssql, tables: ["orders"], database: "shop", schema: "dbo"),
            source: ControllerColumnSource([:])
        )

        let suggestions = await suggest(controller, "SELECT * FROM [ord]", caret: 18)

        #expect(suggestions.contains { $0.label == "orders" })
        #expect(!suggestions.contains { $0.kind == .keyword })
    }

    // The cut 5,000 units back landed inside the comment and read its tail as code.
    @Test("a caret inside a comment longer than the cut offers nothing")
    func longCommentBeforeTheCaret() async {
        let controller = controller(
            scope(.postgresql, tables: ["orders"], database: "shop", schema: "public"),
            source: ControllerColumnSource([:])
        )
        let notes = String(repeating: "notes about the nightly load and its retries\n", count: 140)

        #expect(await suggest(controller, "/*\n" + notes + "SELECT * FROM or").isEmpty)
        #expect(await !suggest(controller, "/*\n" + notes + "it's done */\nSELECT * FROM or").isEmpty)
    }
}
