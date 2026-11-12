//
//  PluginDriverAdapterStatementContextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

private final class ContextRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let declared: PluginCapabilities

    init(capabilities: PluginCapabilities = []) {
        declared = capabilities
    }

    var capabilities: PluginCapabilities { declared }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var recorded: [PluginStatementContext] = []
    private var caps: [Int?] = []

    var contexts: [PluginStatementContext] {
        lock.withLock { recorded }
    }

    var rowCaps: [Int?] {
        lock.withLock { caps }
    }

    private func record(_ context: PluginStatementContext, rowCap: Int? = nil) {
        lock.withLock {
            recorded.append(context)
            caps.append(rowCap)
        }
    }

    private static let empty = PluginQueryResult(
        columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0
    )

    func execute(query: String) async throws -> PluginQueryResult { Self.empty }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        record(context)
        return Self.empty
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record(context)
        return Self.empty
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record(context, rowCap: rowCap)
        return Self.empty
    }

    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        record(context)
        return AsyncThrowingStream { $0.finish() }
    }
}

// A driver that bounds its read under a context, as one declaring `.enforcesReadOnlyMode` does.
private final class BoundingContextDriver: PluginDriverStub, @unchecked Sendable {
    var capabilities: PluginCapabilities { [.readOnlyStatements, .enforcesReadOnlyMode] }

    private let lock = NSLock()
    private var recorded: [PluginStatementContext?] = []

    var boundedContexts: [PluginStatementContext?] {
        lock.withLock { recorded }
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        lock.withLock { recorded.append(nil) }
        return .empty
    }

    func executeBoundedQuery(
        query: String,
        rowCap: Int,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult? {
        lock.withLock { recorded.append(context) }
        return .empty
    }
}

struct PluginDriverAdapterStatementContextTests {
    private func makeAdapter(_ type: DatabaseType, driver: ContextRecordingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    @Test("Every entry point tells the driver a proven MongoDB read is a read")
    func mongoReadIsMarkedOnEveryEntryPoint() async throws {
        let driver = ContextRecordingDriver()
        let adapter = makeAdapter(.mongodb, driver: driver)
        let read = #"db.orders.find({status: "open"}).limit(10)"#

        _ = try await adapter.execute(query: read)
        _ = try await adapter.executeParameterized(query: read, parameters: [1])
        _ = try await adapter.executeUserQuery(query: read, rowCap: 100, parameters: nil)
        for try await _ in adapter.streamRows(query: read) {}

        #expect(driver.contexts.count == 4)
        #expect(driver.contexts.allSatisfy { $0.readOnly })
    }

    @Test(
        "A MongoDB statement that is not a proven read is not marked",
        arguments: ["db.orders.insertOne({a: 1})", "db.orders.find({}).forEach(function (d) { print(d) })"]
    )
    func mongoWriteIsNotMarked(statement: String) async throws {
        let driver = ContextRecordingDriver()
        _ = try await makeAdapter(.mongodb, driver: driver).executeUserQuery(query: statement, rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readOnly } == [false])
    }

    @Test("A Cypher read is marked, so the driver sends it in Bolt's read mode, and a write is not")
    func cypherReadIsMarked() async throws {
        let driver = ContextRecordingDriver()
        let adapter = makeAdapter(.neo4j, driver: driver)
        _ = try await adapter.executeUserQuery(query: "MATCH (n:Person) RETURN n LIMIT 5", rowCap: nil, parameters: nil)
        _ = try await adapter.executeUserQuery(query: "MATCH (n) DETACH DELETE n", rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readOnly } == [true, false])
    }

    @Test("Only a catalog read the app writes reaches the driver marked as one")
    func catalogReadIsMarked() async throws {
        let driver = ContextRecordingDriver()
        let adapter = makeAdapter(.postgresql, driver: driver)
        _ = try await adapter.executeCatalogRead(query: "SELECT 1 FROM pg_catalog.pg_class")
        _ = try await adapter.executeRead(query: "SELECT 1")
        _ = try await adapter.execute(query: "SELECT 1")
        _ = try await adapter.executeUserQuery(query: "SELECT 1", rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readsCatalog } == [true, false, false, false])
        #expect(driver.contexts.first?.readOnly == true)
        #expect(driver.contexts.first?.origin == .app)
    }

    /// A SQL driver ignores the flag, so its statements are not classified for it.
    @Test("A SQL read is not marked")
    func sqlReadIsNotMarked() async throws {
        let driver = ContextRecordingDriver()
        _ = try await makeAdapter(.postgresql, driver: driver).executeUserQuery(query: "SELECT 1", rowCap: nil, parameters: nil)
        #expect(driver.contexts.map { $0.readOnly } == [false])
    }
}

// What an external caller's approval covered reaches the driver with the statement; a run from the app's own
// windows keeps the context it always had.
extension GlobalStateSuites {
    @MainActor
    struct ApprovedOperationStatementContextTests {
        @MainActor
        private final class Installed {
            let driver = ContextRecordingDriver()
            let scope: DatabaseScope
            private let savedBefore: [DatabaseConnection]

            init(_ type: DatabaseType) {
                var connection = TestFixtures.makeConnection(database: "shop", type: type)
                connection.externalAccess = .readWrite
                connection.aiPolicy = .alwaysAllow
                savedBefore = ConnectionStorage.shared.loadConnections()
                ConnectionStorage.shared.saveConnections(savedBefore + [connection])
                var session = ConnectionSession(
                    connection: connection,
                    driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
                )
                session.status = .connected
                DatabaseManager.shared.injectSession(session, for: connection.id)
                scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
            }

            func tearDown() {
                DatabaseManager.shared.removeSession(for: scope.connectionId)
                ConnectionStorage.shared.saveConnections(savedBefore)
            }
        }

        @Test("An approved external read reaches the driver as a read from outside the app, cut by the host")
        func approvedReadCarriesTheApproval() async throws {
            let installed = Installed(.postgresql)
            defer { installed.tearDown() }
            let driver = installed.driver
            let scope = installed.scope
            let bridge = DatabaseAccessBridge()
            let statement = try await bridge.plannedStatement(scope: scope, query: "SELECT 1", maxRows: 10)
            let operation = try await ApprovedOperationFixture.approve(
                [statement], scope: scope, databaseType: .postgresql, capabilities: [.mayWrite]
            )

            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

            let context = try #require(driver.contexts.last)
            #expect(context.readOnly)
            #expect(context.origin == .external)
            #expect(context.hostSplit)
            #expect(!context.allowsServerCode)
            #expect(!context.allowsDestructive)
        }

        @Test("A statement confirm_destructive_operation approved reaches the driver allowed to drop")
        func approvedDropAllowsDestructive() async throws {
            let installed = Installed(.postgresql)
            defer { installed.tearDown() }
            let driver = installed.driver
            let scope = installed.scope
            let services = MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: MCPToolTestHarness.authPolicy(executionGate: AlwaysAllowGate())
            )

            let result = try await ConfirmDestructiveOperationTool().perform(
                arguments: .object([
                    "connection_id": .string(scope.connectionId.uuidString),
                    "query": .string("DROP TABLE orders")
                ]),
                context: MCPToolTestHarness.context(),
                services: services
            )

            #expect(!result.isError)
            let context = try #require(driver.contexts.last)
            #expect(context.allowsDestructive)
            #expect(!context.readOnly)
            #expect(context.origin == .external)
            #expect(!context.allowsServerCode)
        }

        @Test("A read approval is enforced as a read even when its text grades as a write")
        func readApprovalStaysReadOnly() async throws {
            let installed = Installed(.postgresql)
            defer { installed.tearDown() }
            let operation = try await ApprovedOperationFixture.approve(
                [OperationStatement(sql: "UPDATE orders SET total = 0 WHERE id = 1")],
                scope: installed.scope,
                databaseType: .postgresql,
                kind: .readQuery,
                capabilities: [.mayWrite]
            )

            _ = try await DatabaseAccessBridge().runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

            #expect(installed.driver.contexts.last?.readOnly == true)
        }

        @Test("A statement the app runs for itself keeps the default policy and carries the session's lexing")
        func inAppRunKeepsTheDefaultContext() async throws {
            let driver = ContextRecordingDriver()
            let adapter = PluginDriverAdapter(
                connection: DatabaseConnection(name: "Test", type: .postgresql),
                pluginDriver: driver
            )

            _ = try await adapter.executeUserQuery(query: "DELETE FROM orders WHERE id = 1", rowCap: nil, parameters: nil)
            _ = try await adapter.executeParameterized(query: "DELETE FROM orders WHERE id = ?", parameters: [1])

            let features = try #require(driver.contexts.first?.lexicalFeatures)
            #expect(features.contains(.taggedDollarQuotes))
            #expect(!features.contains(.backslashEscapesInSingleQuotes))
            var expected = PluginStatementContext()
            expected.lexicalFeatures = features
            #expect(driver.contexts == [expected, expected])
        }
    }
}

// A driver built before `.statementPolicy` cannot refuse what an approval did not cover, so the adapter refuses an
// external write for it on an engine whose language the host cannot read in full.
struct UnenforcedStatementPolicyTests {
    private static var externalWrite: PluginStatementContext {
        var context = PluginStatementContext()
        context.origin = .external
        context.hostSplit = true
        context.allowsDestructive = false
        context.allowsServerCode = false
        return context
    }

    private static var externalRead: PluginStatementContext {
        var context = externalWrite
        context.readOnly = true
        return context
    }

    private func adapter(_ driver: ContextRecordingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .mongodb), pluginDriver: driver)
    }

    @Test("An older MongoDB driver is refused an external write, on every entry point")
    func olderDriverRefusesExternalWrite() async throws {
        let driver = ContextRecordingDriver()
        let adapter = adapter(driver)
        let write = #"db.c.find(db.c[("delete" + "Many")]({}))"#

        await #expect(throws: ExternalStatementGateError.self) {
            _ = try await adapter.executeUserQuery(query: write, rowCap: nil, parameters: nil, context: Self.externalWrite)
        }
        await #expect(throws: ExternalStatementGateError.self) {
            _ = try await adapter.executeParameterized(query: write, parameters: [], context: Self.externalWrite)
        }
        await #expect(throws: ExternalStatementGateError.self) {
            _ = try await adapter.execute(query: write, context: Self.externalWrite)
        }
        #expect(driver.contexts.isEmpty)
    }

    @Test("An older MongoDB driver still runs an external read and the app's own statements")
    func olderDriverRunsReadsAndInAppWork() async throws {
        let driver = ContextRecordingDriver()
        let adapter = adapter(driver)

        _ = try await adapter.executeUserQuery(
            query: "db.c.find({})", rowCap: nil, parameters: nil, context: Self.externalRead
        )
        _ = try await adapter.executeUserQuery(query: "db.c.insertOne({a: 1})", rowCap: nil, parameters: nil)

        #expect(driver.contexts.count == 2)
    }

    @Test("A MongoDB driver that enforces the policy itself is handed the external write")
    func enforcingDriverGetsTheWrite() async throws {
        let driver = ContextRecordingDriver(capabilities: .statementPolicy)

        _ = try await adapter(driver).executeUserQuery(
            query: "db.c.insertOne({a: 1})", rowCap: nil, parameters: nil, context: Self.externalWrite
        )

        #expect(driver.contexts.map { $0.allowsDestructive } == [false])
    }

    @Test("Only a driver that declares read-only statements reports that it runs them")
    func adapterReportsReadOnlyStatements() {
        #expect(!adapter(ContextRecordingDriver()).runsReadOnlyStatements)
        #expect(adapter(ContextRecordingDriver(capabilities: .readOnlyStatements)).runsReadOnlyStatements)
    }
}

struct PluginDriverAdapterParameterKindTests {
    private func adapter(_ driver: ContextRecordingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .postgresql), pluginDriver: driver)
    }

    @Test("A panel value reaches the driver with the type the user gave it")
    func panelTypesReachTheDriver() async throws {
        let driver = ContextRecordingDriver()
        let values: [Any?] = [
            TypedParameterValue(text: "00123", kind: .text), nil, TypedParameterValue(text: "7", kind: .integer),
        ]

        _ = try await adapter(driver).executeUserQuery(
            query: "SELECT $1, $2, $3", rowCap: nil, parameters: values, context: PluginStatementContext()
        )
        _ = try await adapter(driver).executeParameterized(
            query: "SELECT $1, $2, $3", parameters: values, context: PluginStatementContext()
        )

        #expect(driver.contexts.map { $0.parameterKinds } == [[.text, nil, .integer], [.text, nil, .integer]])
    }

    @Test("Values with no type, such as a grid save's, carry none")
    func untypedValuesCarryNoKinds() async throws {
        let driver = ContextRecordingDriver()

        _ = try await adapter(driver).executeParameterized(
            query: "UPDATE t SET a = $1", parameters: ["42"], context: PluginStatementContext()
        )

        #expect(driver.contexts.map { $0.parameterKinds } == [nil])
    }

    @Test("A typed value is written to the driver as its text")
    func typedValueIsItsText() {
        #expect(PluginDriverAdapter.cellValue(for: TypedParameterValue(text: "1E5", kind: .text)) == .text("1E5"))
    }
}

// Read-Only Safe Mode reaches the driver as `enforcesReadOnly`, only where the driver declares it can hold the engine to
// it, and never on the app's own catalog reads.
struct PluginDriverAdapterReadOnlyModeTests {
    private static let readOnly = PluginStatementContext(enforcesReadOnly: true)

    private func adapter(_ driver: any PluginDatabaseDriver, type: DatabaseType = .postgresql) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    @Test("Only a driver that declares the mode reports that it enforces Read-Only")
    func adapterReportsTheMode() {
        #expect(!adapter(ContextRecordingDriver(capabilities: .readOnlyStatements)).enforcesReadOnlyMode)
        #expect(adapter(ContextRecordingDriver(capabilities: .enforcesReadOnlyMode)).enforcesReadOnlyMode)
    }

    @Test("A run carries the field only at Read-Only and only on a driver that declares the mode")
    func runContextNeedsTheLevelAndTheMode() {
        let enforcing = adapter(ContextRecordingDriver(capabilities: .enforcesReadOnlyMode))
        let older = adapter(ContextRecordingDriver(capabilities: .readOnlyStatements))

        #expect(enforcing.readOnlyRunContext(safeModeIsReadOnly: true)?.enforcesReadOnly == true)
        #expect(enforcing.readOnlyRunContext(safeModeIsReadOnly: false) == nil)
        #expect(older.readOnlyRunContext(safeModeIsReadOnly: true) == nil)
    }

    @Test("Every entry point that takes a context forwards the field to the driver")
    func everyEntryPointForwardsTheField() async throws {
        let driver = ContextRecordingDriver(capabilities: .enforcesReadOnlyMode)
        let adapter = adapter(driver)
        let read = "SELECT purge_orders()"

        _ = try await adapter.executeUserQuery(query: read, rowCap: 100, parameters: nil, context: Self.readOnly)
        _ = try await adapter.executeParameterized(query: "SELECT $1", parameters: [1], context: Self.readOnly)
        _ = try await adapter.execute(query: read, context: Self.readOnly)
        for try await _ in adapter.streamExportRows(query: read, safeModeIsReadOnly: true) {}
        for try await _ in adapter.streamRows(query: read, safeModeIsReadOnly: true) {}

        #expect(driver.contexts.count == 5)
        #expect(driver.contexts.allSatisfy { $0.enforcesReadOnly })
        #expect(driver.contexts.allSatisfy { $0.origin == .app && !$0.readOnly })
    }

    @Test("The bounded read takes the context")
    func boundedReadForwardsTheField() async throws {
        let driver = BoundingContextDriver()
        let adapter = adapter(driver)

        _ = try await adapter.executeBoundedQuery(query: "SELECT 1", rowCap: 10, context: Self.readOnly)
        _ = try await adapter.executeBoundedQuery(query: "SELECT 1", rowCap: 10)

        #expect(driver.boundedContexts.count == 2)
        #expect(driver.boundedContexts.first??.enforcesReadOnly == true)
        #expect(driver.boundedContexts.last == .some(nil))
    }

    @Test("A driver that cannot bound under the context falls back to the user query with the same context and cap")
    func boundedFallbackKeepsTheContext() async throws {
        let driver = ContextRecordingDriver(capabilities: .enforcesReadOnlyMode)
        let adapter = adapter(driver)

        #expect(try await adapter.executeBoundedQuery(query: "SELECT 1", rowCap: 10, context: Self.readOnly) == nil)
        _ = try await QueryExecutor.fetchQueryData(driver: adapter, sql: "SELECT 1", rowCap: 10, context: Self.readOnly)

        #expect(driver.contexts.map { $0.enforcesReadOnly } == [true])
        #expect(driver.rowCaps == [10])
    }

    @Test("At Silent nothing changes: the export stream keeps the default context")
    func silentKeepsTheDefault() async throws {
        let driver = ContextRecordingDriver(capabilities: .enforcesReadOnlyMode)
        let adapter = adapter(driver)

        for try await _ in adapter.streamExportRows(query: "SELECT 1") {}
        _ = try await adapter.executeUserQuery(query: "SELECT 1", rowCap: nil, parameters: nil)

        #expect(driver.contexts.count == 2)
        #expect(driver.contexts.allSatisfy { !$0.enforcesReadOnly })
    }

    @Test("A driver without the mode is never told to enforce it, even at Read-Only")
    func olderDriverIsNotTold() async throws {
        let driver = ContextRecordingDriver(capabilities: .readOnlyStatements)

        for try await _ in adapter(driver).streamExportRows(query: "SELECT 1", safeModeIsReadOnly: true) {}

        #expect(driver.contexts.map { $0.enforcesReadOnly } == [false])
    }

    @Test("A catalog read never carries the field")
    func catalogReadIsNotMarked() async throws {
        let driver = ContextRecordingDriver(capabilities: .enforcesReadOnlyMode)

        _ = try await adapter(driver).executeCatalogRead(query: "SELECT 1 FROM pg_catalog.pg_class")

        #expect(driver.contexts.map { $0.enforcesReadOnly } == [false])
        #expect(driver.contexts.first?.readsCatalog == true)
    }
}
