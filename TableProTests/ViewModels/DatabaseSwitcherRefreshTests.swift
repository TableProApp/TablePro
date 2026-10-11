//
//  DatabaseSwitcherRefreshTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private final class DatabaseNameCountingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var readLog: [String] = []
    private let databaseNames: [String]

    init(connection: DatabaseConnection, databaseNames: [String]) {
        self.connection = connection
        self.databaseNames = databaseNames
    }

    var reads: [String] {
        lock.withLock { readLog }
    }

    func forgetReads() {
        lock.withLock { readLog.removeAll() }
    }

    private func record(_ read: String) {
        lock.withLock { readLog.append(read) }
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] {
        record("databases")
        return databaseNames
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        record("databaseMetadata:\(database)")
        return DatabaseMetadata.minimal(name: database)
    }

    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        record("allDatabaseMetadata")
        return databaseNames.map { DatabaseMetadata.minimal(name: $0) }
    }

    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@MainActor
struct DatabaseSwitcherRefreshTests {
    private func makeViewModel(currentDatabase: String? = nil) -> DatabaseSwitcherViewModel {
        DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: currentDatabase,
            databaseType: .mysql,
            sidebarState: SharedSidebarState()
        )
    }

    private func metadata(_ names: [String]) -> [DatabaseMetadata] {
        names.map { DatabaseMetadata.minimal(name: $0, isSystem: false) }
    }

    /// PGlite opens no pooled connection, so the switcher's read reaches the injected driver.
    private func connect(databaseNames: [String]) -> (DatabaseConnection, DatabaseNameCountingDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = DatabaseNameCountingDriver(connection: connection, databaseNames: databaseNames)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func makeConnectedViewModel(
        _ connection: DatabaseConnection,
        databaseType: DatabaseType = .pglite
    ) -> DatabaseSwitcherViewModel {
        DatabaseSwitcherViewModel(
            connectionId: connection.id,
            currentDatabase: connection.database,
            databaseType: databaseType,
            switchTarget: .database,
            sidebarState: SharedSidebarState()
        )
    }

    @Test("Opening the switcher lists the names and reads no database metadata")
    func switcherReadsDatabaseNamesOnly() async {
        let (connection, driver) = connect(databaseNames: ["testdb", "analytics"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let viewModel = makeConnectedViewModel(connection)

        await viewModel.fetchDatabases()

        #expect(driver.reads == ["databases"])
        #expect(viewModel.databases.map(\.name) == ["analytics", "testdb"])
    }

    @Test("Refreshing the switcher lists the names and reads no database metadata")
    func refreshReadsDatabaseNamesOnly() async {
        let (connection, driver) = connect(databaseNames: ["testdb", "analytics"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let viewModel = makeConnectedViewModel(connection)
        await viewModel.fetchDatabases()
        driver.forgetReads()

        await viewModel.refreshDatabases()

        #expect(driver.reads == ["databases"])
        #expect(viewModel.databases.map(\.name) == ["analytics", "testdb"])
    }

    @Test("A Teradata system database spelled in another case still lists under System")
    func namesOnlyListClassifiesLikeTheEngine() async {
        let (connection, _) = connect(databaseNames: ["dbc", "Sales"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let viewModel = makeConnectedViewModel(connection, databaseType: .teradata)

        await viewModel.fetchDatabases()

        #expect(viewModel.visibleSections.system.map(\.name) == ["dbc"])
        #expect(viewModel.visibleSections.user.map(\.name) == ["Sales"])
    }

    @Test("A database name that differs only in case stays a user database on an engine that keeps case")
    func namesOnlyListKeepsCaseWhereTheEngineDoes() async {
        let (connection, _) = connect(databaseNames: ["MySQL", "mysql"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let viewModel = makeConnectedViewModel(connection, databaseType: .mysql)

        await viewModel.fetchDatabases()

        #expect(viewModel.visibleSections.system.map(\.name) == ["mysql"])
        #expect(viewModel.visibleSections.user.map(\.name) == ["MySQL"])
    }

    @Test("The first load preselects the current database")
    func firstLoadPreselectsCurrent() {
        let viewModel = makeViewModel(currentDatabase: "chinook")

        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))

        #expect(viewModel.selectedDatabase == "chinook")
    }

    @Test("The first load falls back to the first row when there is no current database")
    func firstLoadFallsBackToFirstRow() {
        let viewModel = makeViewModel()

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabase == "analytics")
    }

    /// A refresh can land after the user arrowed to another row, and resetting the selection to the
    /// current database took that row out from under them.
    @Test("A later fetch keeps the selection the user made")
    func laterFetchKeepsUserSelection() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabase = "staging"

        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))

        #expect(viewModel.selectedDatabase == "staging")
    }

    @Test("A selection that no longer exists is replaced")
    func vanishedSelectionIsReplaced() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabase = "staging"

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabase == "chinook")
    }

    @Test("A multiple selection keeps the rows that survived and drops the rest")
    func multipleSelectionIsPruned() {
        let viewModel = makeViewModel()
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabases = ["analytics", "staging"]

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabases == ["analytics"])
    }

    /// Preselecting a row the filter hides left `primarySelection` nil, so Return did nothing and
    /// the switcher looked dead.
    @Test("A fetch under an active filter selects a row the filter shows")
    func fetchUnderFilterSelectsAVisibleRow() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "reporting"]))
        viewModel.searchText = "rep"

        viewModel.applyFetched(metadata(["analytics", "chinook", "reporting"]))

        #expect(viewModel.selectedDatabase == "reporting")
        #expect(viewModel.primarySelection == "reporting")
    }

    @Test("A successful fetch clears an error left by an earlier failure")
    func successClearsTheError() {
        let viewModel = makeViewModel()
        viewModel.errorMessage = "Lost connection"

        viewModel.applyFetched(metadata(["analytics"]))

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isLoading == false)
    }

    /// The CLAUDE.md invariant: a refresh never clears the cache it is refreshing. Nothing is
    /// connected here, so the fetch fails, which is exactly the case being guarded.
    @Test("A failed refresh keeps the loaded list and reports no error")
    func failedRefreshKeepsData() async {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook"]))
        viewModel.selectedDatabase = "analytics"

        await viewModel.fetchDatabases()

        #expect(viewModel.databases.map(\.name) == ["analytics", "chinook"])
        #expect(viewModel.selectedDatabase == "analytics")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isLoading == false)
    }

    @Test("A failed first load reports the error, because there is nothing to fall back on")
    func failedFirstLoadReportsTheError() async {
        let viewModel = makeViewModel()

        await viewModel.fetchDatabases()

        #expect(viewModel.databases.isEmpty)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isLoading == false)
    }
}
