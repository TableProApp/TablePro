//
//  SQLSchemaProviderUnqualifiedScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLSchemaProvider unqualified scope")
struct SQLSchemaProviderUnqualifiedScopeTests {
    private static func postgresDriver() -> MockDatabaseDriver {
        let driver = MockDatabaseDriver(connection: TestFixtures.makeConnection(type: .postgresql))
        driver.currentSchema = "public"
        return driver
    }

    private static func source(_ script: ScriptedSchemaTablesFetch) -> SQLSchemaProvider.ColumnMetadataSource {
        SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in [] },
            fetchAllColumns: { [:] },
            fetchSchemaTables: { _ in try await script.fetch() }
        )
    }

    private static let users = TestFixtures.makeTableInfo(name: "users", schema: "public")
    private static let timesheet = TestFixtures.makeTableInfo(name: "timesheet", schema: "attendance")

    @Test("A table in a schema the tab does not resolve names in is not offered without its schema")
    func expandedSchemaTableIsNotOfferedBare() async {
        let driver = Self.postgresDriver()
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db", tables: [Self.users, Self.timesheet], driver: driver, connection: driver.connection
        )

        let labels = await provider.tableCompletionItems().map(\.label)

        #expect(labels == ["users"])
    }

    @Test("Completing another schema's tables leaves bare completion and the scope's tables alone")
    func qualifiedCompletionDoesNotWidenTheScope() async {
        let script = ScriptedSchemaTablesFetch([.success([Self.timesheet])])
        let driver = Self.postgresDriver()
        let provider = SQLSchemaProvider(metadataSource: Self.source(script))
        await provider.resetForDatabase("db", tables: [Self.users], driver: driver, connection: driver.connection)

        let qualified = await provider.tableCompletionItems(inSchema: "attendance").map(\.label)
        let bare = await provider.tableCompletionItems().map(\.label)
        let scopeTables = await provider.getTables().map(\.name)

        #expect(qualified == ["timesheet"])
        #expect(bare == ["users"])
        #expect(scopeTables == ["users"])
    }

    @Test("A bare FROM prefix never offers a table only another schema holds")
    func bareFromPrefixAfterQualifiedCompletion() async {
        let script = ScriptedSchemaTablesFetch([.success([Self.timesheet])])
        let driver = Self.postgresDriver()
        let schemaProvider = SQLSchemaProvider(metadataSource: Self.source(script))
        await schemaProvider.resetForDatabase(
            "db", tables: [Self.users], driver: driver, connection: driver.connection
        )
        await schemaProvider.setNamespaces(schemas: ["public", "attendance"], databases: ["db"])
        let completion = SQLCompletionProvider(schemaProvider: schemaProvider, databaseType: .postgresql)

        let qualifiedText = "SELECT * FROM attendance."
        let qualified = await completion.getCompletions(
            text: qualifiedText, cursorPosition: (qualifiedText as NSString).length
        ).items
        let bareText = "SELECT * FROM times"
        let bare = await completion.getCompletions(
            text: bareText, cursorPosition: (bareText as NSString).length
        ).items

        #expect(qualified.map(\.label).contains("timesheet"))
        #expect(!bare.contains { $0.insertText.localizedCaseInsensitiveContains("timesheet") })
    }

    @Test("A bare name before a dot resolves only to a table the tab can name without its schema")
    func bareNameResolvesWithinTheUnqualifiedScope() async {
        let driver = Self.postgresDriver()
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db", tables: [Self.users, Self.timesheet], driver: driver, connection: driver.connection
        )
        let reference = TableReference(tableName: "timesheet", alias: "t", schema: "attendance")

        #expect(await provider.resolveAlias("timesheet", in: []) == nil)
        #expect(await provider.resolveAlias("users", in: []) == "users")
        #expect(await provider.resolveAlias("t", in: [reference]) == "timesheet")
        #expect(await provider.resolveAlias("timesheet", in: [reference]) == "timesheet")
    }

    @Test("The engine's implicit schema, not the browsed one, is what a bare name reaches")
    func implicitSchemaDecidesTheUnqualifiedScope() async throws {
        let connection = TestFixtures.makeConnection(type: .spanner)
        let implicitSchema = try #require(connection.type.implicitSchemaName)
        let driver = MockDatabaseDriver(connection: connection)
        driver.currentSchema = "sales"
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db",
            tables: [
                TestFixtures.makeTableInfo(name: "singers", schema: implicitSchema),
                TestFixtures.makeTableInfo(name: "orders", schema: "sales")
            ],
            driver: driver,
            connection: connection
        )

        let labels = await provider.tableCompletionItems().map(\.label)

        #expect(labels == ["singers"])
    }

    @Test("An engine with no current schema offers every table without its schema")
    func engineWithoutCurrentSchemaOffersEveryTable() async {
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db",
            tables: [
                TestFixtures.makeTableInfo(name: "orders"),
                TestFixtures.makeTableInfo(name: "events", schema: "audit")
            ],
            driver: MockDatabaseDriver()
        )

        let labels = await provider.tableCompletionItems().map(\.label)

        #expect(Set(labels) == ["orders", "events"])
    }

    @Test("A schema with no tables is fetched once, not on every keystroke")
    func emptySchemaIsFetchedOnce() async {
        let script = ScriptedSchemaTablesFetch([.success([])])
        let provider = SQLSchemaProvider(metadataSource: Self.source(script))

        let first = await provider.tableCompletionItems(inSchema: "archive")
        let second = await provider.tableCompletionItems(inSchema: "archive")

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(script.calls == 1)
    }

    @Test("A failed fetch of another schema's tables is asked again")
    func failedSchemaFetchIsRetried() async {
        let script = ScriptedSchemaTablesFetch([
            .failure(DatabaseError.queryFailed("timeout")),
            .success([Self.timesheet])
        ])
        let provider = SQLSchemaProvider(metadataSource: Self.source(script))

        let first = await provider.tableCompletionItems(inSchema: "attendance").map(\.label)
        let second = await provider.tableCompletionItems(inSchema: "attendance").map(\.label)

        #expect(first.isEmpty)
        #expect(second == ["timesheet"])
        #expect(script.calls == 2)
    }

    @Test("Concurrent completions of one schema share a single fetch")
    func concurrentSchemaCompletionsShareOneFetch() async {
        let script = ScriptedSchemaTablesFetch([.success([Self.timesheet])], holdsFirstCall: true)
        let provider = SQLSchemaProvider(metadataSource: Self.source(script))

        let first = Task { await provider.tableCompletionItems(inSchema: "attendance").map(\.label) }
        await script.waitForCalls(1)
        let second = Task { await provider.tableCompletionItems(inSchema: "attendance").map(\.label) }
        for _ in 0..<50 where script.calls < 2 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        script.releaseHeldCall()

        #expect(await first.value == ["timesheet"])
        #expect(await second.value == ["timesheet"])
        #expect(script.calls == 1)
    }

    @Test("A fetch a database switch overtook answers its caller and nothing after the switch")
    func overtakenFetchDoesNotAnswerForTheNewScope() async {
        let roster = TestFixtures.makeTableInfo(name: "roster", schema: "attendance")
        let script = ScriptedSchemaTablesFetch([.success([Self.timesheet]), .success([roster])], holdsFirstCall: true)
        let driver = Self.postgresDriver()
        let provider = SQLSchemaProvider(metadataSource: Self.source(script))
        await provider.resetForDatabase("first", tables: [Self.users], driver: driver, connection: driver.connection)

        let overtaken = Task { await provider.tableCompletionItems(inSchema: "attendance").map(\.label) }
        await script.waitForCalls(1)
        await provider.resetForDatabase("second", tables: [Self.users], driver: driver, connection: driver.connection)
        script.releaseHeldCall()
        let overtakenLabels = await overtaken.value

        let fresh = await provider.tableCompletionItems(inSchema: "attendance").map(\.label)
        let bare = await provider.tableCompletionItems().map(\.label)

        #expect(overtakenLabels == ["timesheet"])
        #expect(fresh == ["roster"])
        #expect(bare == ["users"])
        #expect(script.calls == 2)
    }
}

/// Answers `fetchSchemaTables` from a list, one answer per call with the last repeated, and can
/// hold the first call until the test releases it.
private final class ScriptedSchemaTablesFetch: @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [Result<[TableInfo], any Error>]
    private let holdsFirstCall: Bool
    private var startedCalls = 0
    private var arrivedCalls = 0
    private var heldCall: CheckedContinuation<Void, Never>?
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ answers: [Result<[TableInfo], any Error>], holdsFirstCall: Bool = false) {
        self.answers = answers
        self.holdsFirstCall = holdsFirstCall
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrivedCalls
    }

    func fetch() async throws -> [TableInfo] {
        let index = reserveCall()
        let answer = answers[min(index, answers.count - 1)]
        if index == 0 && holdsFirstCall {
            await withCheckedContinuation { continuation in
                hold(continuation)
                noteArrival()
            }
        } else {
            noteArrival()
        }
        return try answer.get()
    }

    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            enqueueWaiter(count: count, continuation)
        }
    }

    func releaseHeldCall() {
        lock.lock()
        let held = heldCall
        heldCall = nil
        lock.unlock()
        held?.resume()
    }

    private func reserveCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = startedCalls
        startedCalls += 1
        return index
    }

    private func hold(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        heldCall = continuation
        lock.unlock()
    }

    private func noteArrival() {
        lock.lock()
        arrivedCalls += 1
        let arrived = arrivedCalls
        let ready = callWaiters.filter { $0.count <= arrived }
        callWaiters.removeAll { $0.count <= arrived }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    private func enqueueWaiter(count: Int, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard arrivedCalls < count else {
            lock.unlock()
            continuation.resume()
            return
        }
        callWaiters.append((count, continuation))
        lock.unlock()
    }
}
