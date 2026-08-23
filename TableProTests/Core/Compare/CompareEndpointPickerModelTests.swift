//
//  CompareEndpointPickerModelTests.swift
//  TableProTests
//
//  The chooser's loading rules. Each of these was a defect in the NSMenu this
//  replaced, where a failed connect was cached as an empty database list and
//  every submenu open refetched.
//

@testable import TablePro
import XCTest

@MainActor
final class CompareEndpointPickerModelTests: XCTestCase {
    private struct Unreachable: LocalizedError {
        var errorDescription: String? { "Connection refused" }
    }

    private func connection(name: String = "Prod") -> DatabaseConnection {
        DatabaseConnection(name: name, type: .postgresql)
    }

    private func model(
        databases: @escaping (DatabaseConnection) async throws -> [String] = { _ in [] },
        schemas: @escaping (CompareSyncEndpoint, DatabaseConnection) async throws -> [String] = { _, _ in [] }
    ) -> CompareEndpointPickerModel {
        CompareEndpointPickerModel(databaseLoader: databases, schemaLoader: schemas)
    }

    func testAnUnopenedConnectionReportsLoadingRatherThanAnEmptyList() {
        XCTAssertEqual(model().databases(for: UUID()), .loading)
    }

    func testDatabasesAreLoadedOnce() async {
        let calls = Counter()
        let subject = model(databases: { _ in
            calls.increment()
            return ["orders"]
        })
        let connection = connection()

        await subject.loadDatabases(for: connection)
        await subject.loadDatabases(for: connection)

        XCTAssertEqual(calls.value, 1, "reopening the chooser must not refetch")
        XCTAssertEqual(subject.databases(for: connection.id), .loaded(["orders"]))
    }

    /// A server that refused the connection is not a server with no databases. Caching the failure
    /// as `[]` is what told users their database list was empty, with no way to retry.
    func testAFailedLoadIsRememberedAsAFailure() async {
        let subject = model(databases: { _ in throw Unreachable() })
        let connection = connection()

        await subject.loadDatabases(for: connection)

        XCTAssertEqual(subject.databases(for: connection.id), .failed("Connection refused"))
    }

    func testAFailedLoadCanBeRetriedWithoutAskingForAReload() async {
        let calls = Counter()
        let subject = model(databases: { _ in
            calls.increment()
            guard calls.value > 1 else { throw Unreachable() }
            return ["orders"]
        })
        let connection = connection()

        await subject.loadDatabases(for: connection)
        await subject.loadDatabases(for: connection)

        XCTAssertEqual(subject.databases(for: connection.id), .loaded(["orders"]))
    }

    /// `CLAUDE.md`: a refresh never clears the cache it is refreshing. The list stays on screen
    /// while the reload runs, so Try Again cannot blank a pane that already had an answer.
    func testAReloadKeepsTheLoadedListUntilTheNewOneArrives() async {
        let gate = AsyncGate()
        let subject = model(databases: { _ in
            await gate.wait()
            return ["orders", "audit"]
        })
        let connection = connection()

        await gate.open()
        await subject.loadDatabases(for: connection)
        await gate.close()

        let reload = Task { await subject.loadDatabases(for: connection, reload: true) }
        await Task.yield()
        XCTAssertEqual(subject.databases(for: connection.id), .loaded(["orders", "audit"]))

        await gate.open()
        await reload.value
        XCTAssertEqual(subject.databases(for: connection.id), .loaded(["orders", "audit"]))
    }

    func testSchemasAreKeyedPerDatabaseRatherThanPerConnection() async {
        let subject = model(schemas: { endpoint, _ in [endpoint.database + "_schema"] })
        let connection = connection()
        let orders = CompareSyncEndpoint.from(connection: connection, database: "orders")
        let audit = CompareSyncEndpoint.from(connection: connection, database: "audit")

        await subject.loadSchemas(for: orders, connection: connection)
        await subject.loadSchemas(for: audit, connection: connection)

        XCTAssertEqual(subject.schemas(for: orders), .loaded(["orders_schema"]))
        XCTAssertEqual(subject.schemas(for: audit), .loaded(["audit_schema"]))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func close() {
        isOpen = false
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
