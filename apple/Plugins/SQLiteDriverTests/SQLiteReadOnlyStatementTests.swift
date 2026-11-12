//
//  SQLiteReadOnlyStatementTests.swift
//  SQLiteDriverTests
//

import CSQLite
import Foundation
import TableProPluginKit
import TableProSQLiteCore
import Testing

struct SQLiteReadOnlyStatementTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-read-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private static var external: PluginStatementContext {
        var context = PluginStatementContext()
        context.origin = .external
        context.hostSplit = true
        context.allowsServerCode = false
        return context
    }

    private static var externalRead: PluginStatementContext {
        var context = external
        context.readOnly = true
        return context
    }

    private static var safeMode: PluginStatementContext {
        PluginStatementContext(enforcesReadOnly: true)
    }

    private func connect(_ database: String) async throws -> SQLitePluginDriver {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: database
        ))
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE kept (a INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (1)")
        return driver
    }

    private func count(_ driver: SQLitePluginDriver) async throws -> String? {
        try await driver.execute(query: "SELECT count(*) FROM kept").rows.first?.first?.asText
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test("The driver says it runs a read-only statement in SQLite's own read-only mode, from outside and at Read-Only")
    func declaresReadOnlyStatements() {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path("app.db")
        ))
        #expect(driver.capabilities.contains(.readOnlyStatements))
        #expect(driver.capabilities.contains(.enforcesReadOnlyMode))
    }

    @Test("Read-Only reads read-only under the session's own scope, an external read under the read-only scope")
    func rulesFollowTheContext() {
        var externalSafeModeWrite = Self.external
        externalSafeModeWrite.enforcesReadOnly = true
        var catalogRead = PluginStatementContext()
        catalogRead.readOnly = true
        catalogRead.readsCatalog = true

        #expect(SQLiteStatementRules(PluginStatementContext()) == .unrestricted)
        #expect(SQLiteStatementRules(catalogRead) == .unrestricted)
        #expect(SQLiteStatementRules(Self.safeMode) == SQLiteStatementRules(scope: .unrestricted, readsOnly: true))
        #expect(SQLiteStatementRules(Self.externalRead) == SQLiteStatementRules(scope: .readOnly, readsOnly: true))
        #expect(SQLiteStatementRules(Self.external) == SQLiteStatementRules(scope: .noServerCode, readsOnly: false))
        #expect(SQLiteStatementRules(externalSafeModeWrite) == SQLiteStatementRules(scope: .noServerCode, readsOnly: true))
        #expect(SQLiteAgentBackend.agentScope(SQLiteStatementRules(Self.safeMode)) == .readOnly)
        #expect(SQLiteAgentBackend.agentScope(.unrestricted) == nil)
        #expect(SQLiteAgentBackend.agentScope(SQLiteStatementRules(Self.external)) == .noServerCode)
    }

    // An application function that deletes through its own connection: the shape of a SQL function that writes.
    private static let purgeKept: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, _, _ in
        let db = sqlite3_context_db_handle(context)
        guard sqlite3_exec(db, "DELETE FROM kept", nil, nil, nil) == SQLITE_OK else {
            sqlite3_result_error(context, sqlite3_errmsg(db), -1)
            return
        }
        sqlite3_result_int(context, 1)
    }

    private typealias ExtensionEntryPoint = @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeRawPointer?
    ) -> Int32

    private static let registerPurgeKept: ExtensionEntryPoint = { db, _, _ in
        sqlite3_create_function(db, "purge_kept", 0, SQLITE_UTF8, nil, SQLiteReadOnlyStatementTests.purgeKept, nil, nil)
    }

    // The driver opens its own handle, so the function goes onto every handle opened while the driver connects.
    private func connectWithPurgeKept() async throws -> SQLitePluginDriver {
        let entry = unsafeBitCast(Self.registerPurgeKept, to: (@convention(c) () -> Void).self)
        #expect(sqlite3_auto_extension(entry) == SQLITE_OK)
        defer { sqlite3_cancel_auto_extension(entry) }
        return try await connect(path("app.db"))
    }

    @Test("At Read-Only a function that writes is refused on every entry point, and the default context lets it write")
    func safeModeRefusesAWritingFunction() async throws {
        let driver = try await connectWithPurgeKept()
        defer { driver.disconnect() }
        let call = "SELECT purge_kept()"

        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(query: call, context: Self.safeMode)
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeUserQuery(query: call, rowCap: 100, parameters: nil, context: Self.safeMode)
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeParameterized(
                query: "SELECT purge_kept(), ?", parameters: [.null], context: Self.safeMode
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeBoundedQuery(query: call, rowCap: 100, context: Self.safeMode)
        }
        await #expect(throws: (any Error).self) {
            for try await _ in driver.streamRows(query: call, context: Self.safeMode) {}
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(query: call, context: Self.externalRead)
        }
        #expect(try await count(driver) == "1")
        #expect(try await driver.execute(query: "PRAGMA query_only").rows.first?.first?.asText == "0")

        _ = try await driver.execute(query: call, context: PluginStatementContext())
        #expect(try await count(driver) == "0")
    }

    @Test("At Read-Only a write is refused, a read runs, and the default context still writes")
    func safeModeRefusesWrites() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }

        for sql in ["INSERT INTO kept VALUES (2)", "UPDATE kept SET a = 5", "CREATE TABLE added (a INTEGER)"] {
            await #expect(throws: (any Error).self, "\(sql)") {
                _ = try await driver.execute(query: sql, context: Self.safeMode)
            }
        }
        let safeModeRefusal = await #expect(throws: SQLitePluginError.self) {
            _ = try await driver.executeUserQuery(
                query: "DELETE FROM kept", rowCap: 10, parameters: nil, context: Self.safeMode
            )
        }
        #expect(safeModeRefusal?.pluginErrorMessage == SQLitePluginError.safeModeReadOnlyStatement.pluginErrorMessage)
        let externalRefusal = await #expect(throws: SQLitePluginError.self) {
            _ = try await driver.execute(query: "DELETE FROM kept", context: Self.externalRead)
        }
        #expect(externalRefusal?.pluginErrorMessage == SQLitePluginError.readOnlyStatement.pluginErrorMessage)
        let read = try await driver.executeBoundedQuery(query: "SELECT a FROM kept", rowCap: 10, context: Self.safeMode)
        #expect(read?.rows.compactMap { $0.first?.asText } == ["1"])
        #expect(read?.isTruncated == false)
        #expect(try await count(driver) == "1")

        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2)", context: PluginStatementContext())
        #expect(try await count(driver) == "2")
    }

    @Test("A bounded read the read-only mode does not cover goes back to the host")
    func boundedReadGoesBackWhenNotCovered() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        var catalogRead = PluginStatementContext()
        catalogRead.readOnly = true
        catalogRead.readsCatalog = true

        #expect(try await driver.executeBoundedQuery(query: "SELECT a FROM kept", rowCap: 10, context: catalogRead) == nil)
        #expect(try await driver.executeBoundedQuery(query: "SELECT a FROM kept", rowCap: 10, context: Self.external) == nil)
        let plain = try await driver.executeBoundedQuery(
            query: "SELECT a FROM kept", rowCap: 10, context: PluginStatementContext()
        )
        #expect(plain?.rows.count == 1)
    }

    @Test("A read-only read stops at the first row past the byte limit and keeps that row")
    func readOnlyReadStopsAtTheByteLimit() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "DELETE FROM kept")
        // Each value reads as six bytes of text.
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (100000), (200000), (300000), (400000)")
        let sql = "SELECT a FROM kept ORDER BY a"
        var limited = Self.externalRead
        limited.resultByteLimit = 10
        var safeModeLimited = Self.safeMode
        safeModeLimited.resultByteLimit = 10

        let capped = try await driver.executeUserQuery(query: sql, rowCap: 100, parameters: nil, context: limited)
        #expect(capped.rows.compactMap { $0.first?.asText } == ["100000", "200000"])
        #expect(capped.isTruncated)

        let whole = try await driver.execute(query: sql, context: limited)
        #expect(whole.rows.count == 2)
        #expect(whole.isTruncated)

        let bounded = try await driver.executeBoundedQuery(query: sql, rowCap: 100, context: safeModeLimited)
        #expect(bounded?.rows.count == 2)
        #expect(bounded?.isTruncated == true)

        let capFirst = try await driver.executeUserQuery(query: sql, rowCap: 1, parameters: nil, context: limited)
        #expect(capFirst.rows.compactMap { $0.first?.asText } == ["100000"])
        #expect(capFirst.isTruncated)

        var roomy = Self.externalRead
        roomy.resultByteLimit = 1_000
        let all = try await driver.executeUserQuery(query: sql, rowCap: 100, parameters: nil, context: roomy)
        #expect(all.rows.count == 4)
        #expect(!all.isTruncated)
    }

    @Test("A read bound exists only when a cap or a byte limit is set, and a row's size is its decoded bytes")
    func readBoundShape() {
        #expect(SQLiteReadBound.ifSet(rowCap: nil, byteLimit: nil) == nil)
        #expect(SQLiteReadBound.ifSet(rowCap: 0, byteLimit: nil) == nil)
        #expect(SQLiteReadBound.ifSet(rowCap: nil, byteLimit: 5)?.rowCap == PluginRowLimits.emergencyMax)
        #expect(SQLiteReadBound.ifSet(rowCap: 7, byteLimit: nil) == SQLiteReadBound(rowCap: 7, byteLimit: nil))
        #expect(SQLiteReadBound.byteCount(of: [.null, .text("héllo"), .bytes(Data(count: 4))]) == 10)
    }

    @Test("A read-only statement that writes, attaches or copies the database is refused and changes nothing", arguments: [
        "INSERT INTO kept VALUES (2)",
        "CREATE TABLE added (a INTEGER)",
        "ATTACH DATABASE '%@/attached.db' AS other",
        "VACUUM INTO '%@/copy.db'",
        "PRAGMA journal_mode = WAL",
        "PRAGMA query_only = 0",
        "BEGIN",
        "SELECT load_extension('%@/missing.dylib')",
    ])
    func writeIsRefused(template: String) async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        let before = try files()
        let sql = template.replacingOccurrences(of: "%@", with: directory.path)

        await #expect(throws: (any Error).self) {
            _ = try await driver.executeUserQuery(query: sql, rowCap: nil, parameters: nil, context: Self.externalRead)
        }
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeUserQuery(query: sql, rowCap: 100, parameters: nil, context: Self.externalRead)
        }

        #expect(try files() == before)
        #expect(try await count(driver) == "1")
        let tables = try await driver.execute(query: "SELECT name FROM sqlite_master").rows.compactMap { $0.first?.asText }
        #expect(tables == ["kept"])
        let mode = try await driver.execute(query: "PRAGMA journal_mode").rows.first?.first?.asText
        #expect(mode == "delete")
    }

    @Test("A read-only EXPLAIN of a write returns its plan and runs nothing", arguments: [
        "EXPLAIN QUERY PLAN UPDATE kept SET a = 5",
        "EXPLAIN DELETE FROM kept",
    ])
    func explainOfAWriteRuns(sql: String) async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }

        let plan = try await driver.execute(query: sql, context: Self.externalRead)
        #expect(!plan.rows.isEmpty)
        #expect(try await count(driver) == "1")
    }

    @Test("A read-only SELECT reads, whole, capped, bound and streamed")
    func readRuns() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2), (3)")

        let whole = try await driver.execute(query: "SELECT a FROM kept ORDER BY a", context: Self.externalRead)
        #expect(whole.rows.compactMap { $0.first?.asText } == ["1", "2", "3"])

        let capped = try await driver.executeUserQuery(
            query: "SELECT a FROM kept ORDER BY a", rowCap: 2, parameters: nil, context: Self.externalRead
        )
        #expect(capped.rows.count == 2)
        #expect(capped.isTruncated)

        let bound = try await driver.executeUserQuery(
            query: "SELECT a FROM kept WHERE a = ?", rowCap: nil, parameters: [.text("2")], context: Self.externalRead
        )
        #expect(bound.rows.compactMap { $0.first?.asText } == ["2"])

        let info = try await driver.execute(query: "PRAGMA table_info(kept)", context: Self.externalRead)
        #expect(info.rows.first?[safe: 1]?.asText == "a")

        var streamed = 0
        for try await element in driver.streamRows(query: "SELECT a FROM kept", context: Self.externalRead) {
            if case .rows(let rows) = element { streamed += rows.count }
        }
        #expect(streamed == 3)
    }

    @Test("A read-only statement sees an attached database and cannot write to it")
    func attachedDatabaseIsReadOnly() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "ATTACH DATABASE '\(path("aux.db"))' AS aux")
        _ = try await driver.execute(query: "CREATE TABLE aux.notes (b TEXT)")
        _ = try await driver.execute(query: "INSERT INTO aux.notes VALUES ('kept')")

        let read = try await driver.execute(query: "SELECT b FROM aux.notes", context: Self.externalRead)
        #expect(read.rows.first?.first?.asText == "kept")
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(query: "INSERT INTO aux.notes VALUES ('added')", context: Self.externalRead)
        }
        let after = try await driver.execute(query: "SELECT count(*) FROM aux.notes")
        #expect(after.rows.first?.first?.asText == "1")
    }

    @Test("A session's temporary table hides the main one for a read-only statement too, and a write is still refused")
    func temporaryTableResolvesAsInTheSession() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE TABLE Album (title TEXT)")
        _ = try await driver.execute(query: "INSERT INTO main.Album VALUES ('main')")
        _ = try await driver.execute(query: "CREATE TEMP TABLE Album (title TEXT)")
        _ = try await driver.execute(query: "INSERT INTO temp.Album VALUES ('temp')")

        let read = try await driver.execute(query: "SELECT title FROM Album", context: Self.externalRead)
        #expect(read.rows.compactMap { $0.first?.asText } == ["temp"])
        let capped = try await driver.executeUserQuery(
            query: "SELECT title FROM Album", rowCap: 10, parameters: nil, context: Self.externalRead
        )
        #expect(capped.rows.compactMap { $0.first?.asText } == ["temp"])

        for sql in ["INSERT INTO Album VALUES ('added')", "INSERT INTO main.kept VALUES (2)", "PRAGMA query_only = 0"] {
            await #expect(throws: (any Error).self, "\(sql)") {
                _ = try await driver.execute(query: sql, context: Self.externalRead)
            }
        }
        let rows = try await driver.execute(query: "SELECT count(*) FROM temp.Album").rows
        #expect(rows.first?.first?.asText == "1")
        #expect(try await count(driver) == "1")
        _ = try await driver.execute(query: "INSERT INTO temp.Album VALUES ('after')")
    }

    @Test("A database attached without a file resolves as in the session")
    func memoryAttachmentResolvesAsInTheSession() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "ATTACH DATABASE ':memory:' AS scratch")
        _ = try await driver.execute(query: "CREATE TABLE scratch.notes (b TEXT)")
        _ = try await driver.execute(query: "INSERT INTO scratch.notes VALUES ('kept')")

        let read = try await driver.execute(query: "SELECT b FROM scratch.notes", context: Self.externalRead)
        #expect(read.rows.first?.first?.asText == "kept")
        await #expect(throws: (any Error).self) {
            _ = try await driver.execute(query: "DELETE FROM scratch.notes", context: Self.externalRead)
        }
    }

    @Test("A read-only statement reads the session's last_insert_rowid() and changes()")
    func connectionStateReadsAsInTheSession() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2), (3)")

        let read = try await driver.execute(query: "SELECT last_insert_rowid(), changes()", context: Self.externalRead)
        #expect(read.rows.first?.compactMap { $0.asText } == ["3", "2"])
        let inApp = try await driver.execute(query: "SELECT last_insert_rowid(), changes()")
        #expect(inApp.rows == read.rows)
    }

    @Test("A read-only statement sees the session's open transaction as the session does and cannot end it")
    func sessionTransactionSurvives() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "BEGIN")
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2)")

        let read = try await driver.execute(query: "SELECT count(*) FROM kept", context: Self.externalRead)
        #expect(read.rows.first?.first?.asText == "2")
        for sql in ["COMMIT", "ROLLBACK", "SAVEPOINT s"] {
            await #expect(throws: (any Error).self, "\(sql)") {
                _ = try await driver.execute(query: sql, context: Self.externalRead)
            }
        }
        #expect(await driver.sessionTransactionState() == .inTransaction)

        _ = try await driver.execute(query: "COMMIT")
        #expect(try await count(driver) == "2")
    }

    @Test("Without a file, a read-only statement runs on the session's handle and still cannot write")
    func inMemoryReadOnly() async throws {
        let driver = try await connect(":memory:")
        defer { driver.disconnect() }

        let read = try await driver.execute(query: "SELECT count(*) FROM kept", context: Self.externalRead)
        #expect(read.rows.first?.first?.asText == "1")
        for sql in ["INSERT INTO kept VALUES (2)", "PRAGMA query_only = 0", "BEGIN", "ATTACH DATABASE '\(path("m.db"))' AS m"] {
            await #expect(throws: (any Error).self, "\(sql)") {
                _ = try await driver.execute(query: sql, context: Self.externalRead)
            }
        }

        #expect(try await count(driver) == "1")
        #expect(try files().isEmpty)
        let queryOnly = try await driver.execute(query: "PRAGMA query_only").rows.first?.first?.asText
        #expect(queryOnly == "0")
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2)")
        #expect(try await count(driver) == "2")
    }

    @Test("The default context still writes, attaches and detaches")
    func defaultContextWrites() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }

        _ = try await driver.execute(query: "INSERT INTO kept VALUES (2)", context: PluginStatementContext())
        _ = try await driver.executeUserQuery(
            query: "ATTACH DATABASE '\(path("other.db"))' AS other", rowCap: nil, parameters: nil, context: PluginStatementContext()
        )
        _ = try await driver.execute(query: "DETACH other", context: PluginStatementContext())

        #expect(try await count(driver) == "2")
        #expect(try files().contains("other.db"))
    }

    @Test("A write that may not reach server code cannot attach or copy the database, and still writes")
    func writeWithoutServerCode() async throws {
        let driver = try await connect(path("app.db"))
        defer { driver.disconnect() }

        for sql in [
            "ATTACH DATABASE '\(path("attached.db"))' AS other",
            "ATTACH DATABASE ('\(path("attached.db"))' || '') AS other",
            "VACUUM INTO '\(path("copy.db"))'",
        ] {
            await #expect(throws: (any Error).self, "\(sql)") {
                _ = try await driver.execute(query: sql, context: Self.external)
            }
        }
        _ = try await driver.execute(query: "INSERT INTO kept VALUES (upper('2'))", context: Self.external)
        _ = try await driver.execute(query: "ALTER TABLE kept RENAME TO moved", context: Self.external)
        _ = try await driver.execute(query: "ALTER TABLE moved ADD COLUMN b TEXT", context: Self.external)
        _ = try await driver.execute(query: "VACUUM", context: Self.external)

        #expect(try files() == ["app.db"])
        let rows = try await driver.execute(query: "SELECT count(*) FROM moved").rows
        #expect(rows.first?.first?.asText == "2")
    }

    private static let writeFile: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, _, _ in
        sqlite3_result_int(context, 1)
    }

    private static func prepares(_ db: OpaquePointer, _ sql: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
    }

    private func openHandle() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path("app.db"), &db) == SQLITE_OK, let db else { throw SQLitePluginError.notConnected }
        #expect(sqlite3_exec(db, "CREATE TABLE kept (a INTEGER)", nil, nil, nil) == SQLITE_OK)
        return db
    }

    private static func text(_ db: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }

    @Test("Outside the default scope, a function an extension added is refused and a built-in one runs")
    func extensionFunctionNeedsServerCode() throws {
        let db = try openHandle()
        defer { sqlite3_close(db) }
        let added = SQLiteAuthorizerPolicy.extensionNames(on: db) {
            sqlite3_create_function(db, "writefile", 1, SQLITE_UTF8, nil, Self.writeFile, nil, nil)
        }
        #expect(added == SQLiteExtensionNames(functions: ["writefile"], modules: []))
        let policy = SQLiteAuthorizerPolicy(extensions: added)
        SQLiteAuthorizer.install(on: db, policy: policy)

        #expect(Self.prepares(db, "SELECT writefile('x')"))
        for scope in [SQLiteStatementScope.noServerCode, .readOnly] {
            policy.scope = scope
            #expect(!Self.prepares(db, "SELECT WriteFile('x')"))
            #expect(Self.prepares(db, "SELECT upper('x'), count(*) FROM kept"))
        }
        policy.scope = .unrestricted
        #expect(!Self.prepares(db, "SELECT load_extension('x')"))
    }

    @Test("An extension's eponymous virtual table is refused to external reads and writes, and in-app reads it")
    func extensionTableNeedsServerCode() throws {
        let db = try openHandle()
        defer { sqlite3_close(db) }
        let added = SQLiteAuthorizerPolicy.extensionNames(on: db) { SecretTable.register(on: db) }
        #expect(added == SQLiteExtensionNames(functions: [], modules: ["secret"]))
        let policy = SQLiteAuthorizerPolicy(extensions: added)
        SQLiteAuthorizer.install(on: db, policy: policy)

        #expect(Self.text(db, "SELECT data FROM secret") == SecretTable.value)
        policy.scope = .readOnly
        for sql in ["SELECT data FROM secret", "SELECT count(*) FROM Secret", "SELECT a FROM kept, secret"] {
            #expect(!Self.prepares(db, sql), "\(sql)")
        }
        #expect(Self.text(db, "SELECT count(*) FROM kept") == "0")
        policy.scope = .noServerCode
        #expect(!Self.prepares(db, "INSERT INTO kept SELECT length(data) FROM secret"))
        #expect(Self.prepares(db, "INSERT INTO kept VALUES (1)"))
        policy.scope = .unrestricted
        #expect(Self.text(db, "SELECT count(*) FROM secret") == "1")
    }

    @Test("A module list SQLite could not give refuses every table outside the default scope")
    func unknownModulesRefuseTables() throws {
        let db = try openHandle()
        defer { sqlite3_close(db) }
        let policy = SQLiteAuthorizerPolicy(extensions: SQLiteExtensionNames(functions: [], modules: nil), scope: .readOnly)
        SQLiteAuthorizer.install(on: db, policy: policy)
        #expect(!Self.prepares(db, "SELECT count(*) FROM kept"))
        policy.scope = .unrestricted
        #expect(Self.prepares(db, "SELECT count(*) FROM kept"))
    }

    @Test("A scoped execute is the execute payload, then the scope, under its own opcode")
    func scopedExecuteFrame() throws {
        let frame = SQLiteAgentFrameEncoder.encode(
            SQLiteAgentRequest.executeScoped(sql: "S", parameters: [.null], rowCap: 7, scope: .readOnly)
        )
        let payload: [UInt8] = [0, 0, 0, 1] + Array("S".utf8) + [0, 0, 0, 1, 0] + [0, 0, 0, 7] + [2]
        #expect(frame == Data([0, 0, 0, UInt8(payload.count + 1), 0x06] + payload))

        var reader = SQLiteAgentFrameReader()
        reader.append(frame)
        #expect(try reader.nextRequest() == .executeScoped(sql: "S", parameters: [.null], rowCap: 7, scope: .readOnly))

        var unknown = SQLiteAgentFrameReader()
        unknown.append(Data([0, 0, 0, UInt8(payload.count + 1), 0x06] + payload.dropLast() + [9]))
        #expect(throws: SQLiteAgentProtocolError.unknownScope(9)) { _ = try unknown.nextRequest() }
    }
}

// One row with one column, `data`: an eponymous virtual table like fileio's `fsdir`, which reads files with no
// function call.
private enum SecretTable {
    static let value = "secret"
    private static let rowOffset = MemoryLayout<sqlite3_vtab_cursor>.stride

    private static func row(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?) -> UnsafeMutablePointer<Int32>? {
        cursor.map { UnsafeMutableRawPointer($0).advanced(by: rowOffset).assumingMemoryBound(to: Int32.self) }
    }

    static func register(on db: OpaquePointer) {
        let module = UnsafeMutablePointer<sqlite3_module>.allocate(capacity: 1)
        module.initialize(to: sqlite3_module())
        module.pointee.xConnect = { db, _, _, _, table, _ in
            let declared = sqlite3_declare_vtab(db, "CREATE TABLE x(data TEXT)")
            guard declared == SQLITE_OK else { return declared }
            let vtab = UnsafeMutablePointer<sqlite3_vtab>.allocate(capacity: 1)
            vtab.initialize(to: sqlite3_vtab())
            table?.pointee = vtab
            return SQLITE_OK
        }
        module.pointee.xBestIndex = { _, _ in SQLITE_OK }
        module.pointee.xDisconnect = { table in
            table?.deallocate()
            return SQLITE_OK
        }
        module.pointee.xOpen = { _, cursor in
            let raw = UnsafeMutableRawPointer.allocate(byteCount: SecretTable.rowOffset + 8, alignment: 8)
            let base = raw.initializeMemory(as: sqlite3_vtab_cursor.self, repeating: sqlite3_vtab_cursor(), count: 1)
            raw.advanced(by: SecretTable.rowOffset).initializeMemory(as: Int32.self, repeating: 0, count: 1)
            cursor?.pointee = base
            return SQLITE_OK
        }
        module.pointee.xClose = { cursor in
            cursor.map { UnsafeMutableRawPointer($0).deallocate() }
            return SQLITE_OK
        }
        module.pointee.xFilter = { cursor, _, _, _, _ in
            SecretTable.row(cursor)?.pointee = 0
            return SQLITE_OK
        }
        module.pointee.xNext = { cursor in
            SecretTable.row(cursor)?.pointee += 1
            return SQLITE_OK
        }
        module.pointee.xEof = { cursor in
            (SecretTable.row(cursor)?.pointee ?? 1) >= 1 ? 1 : 0
        }
        module.pointee.xColumn = { _, context, _ in
            sqlite3_result_text(context, SecretTable.value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return SQLITE_OK
        }
        module.pointee.xRowid = { _, rowid in
            rowid?.pointee = 1
            return SQLITE_OK
        }
        sqlite3_create_module_v2(db, "secret", module, UnsafeMutableRawPointer(module)) { data in
            data?.assumingMemoryBound(to: sqlite3_module.self).deallocate()
        }
    }
}
