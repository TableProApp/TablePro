import Foundation
@testable import TableProTeradataCore
import Testing

private enum TeradataWire {
    static let varchar: UInt16 = 449
    static let finished = reply([Parcel(.success), Parcel(.endRequest)])

    static func reply(_ parcels: [Parcel]) -> [UInt8] {
        LanMessage(kind: .start, body: parcels.flatMap { $0.encoded() }).encoded()
    }

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func prepInfoX(_ columns: [(type: UInt16, length: Int, name: String)]) -> Parcel {
        var body = [UInt8](repeating: 0, count: 8) + u16(0) + u16(columns.count)
        for column in columns {
            let name = Array(column.name.utf8)
            body += u16(Int(column.type))
            body += (0..<8).map { UInt8(truncatingIfNeeded: column.length >> (8 * (7 - $0))) }
            body += [0, 0]
            body += u16(name.count) + name
            body += u16(0) + u16(0)
        }
        return Parcel(.prepInfoX, body: body)
    }

    // One row of VARCHAR columns, each named and holding the text given.
    static func textRow(_ cells: [(name: String, value: String)]) -> [UInt8] {
        let header = prepInfoX(cells.map { (type: varchar, length: 64, name: $0.name) })
        var record = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for cell in cells {
            let text = Array(cell.value.utf8)
            record += u16(text.count) + text
        }
        return reply([Parcel(.success), header, Parcel(.record, body: record), Parcel(.endRequest)])
    }

    static func failure(code: Int, _ message: String = "refused") -> [UInt8] {
        let text = Array(message.utf8)
        return reply([Parcel(.failure, body: [UInt8](repeating: 0, count: 8) + u16(code) + u16(text.count) + text)])
    }

    static func connection(
        _ replies: [[UInt8]],
        mode: TeradataTransactionMode,
        database: String? = nil
    ) -> (TeradataConnection, StoppableTransport) {
        let transport = StoppableTransport(replies: replies)
        let config = TeradataConnectionConfig(
            host: "td.example", username: "dbc", password: "dbc", database: database, transactionMode: mode
        )
        return (TeradataConnection(config: config, transport: transport), transport)
    }

    static func sentSQL(_ transport: StoppableTransport) throws -> [String] {
        try transport.sent.compactMap { message in
            try Parcel.decodeAll(message.body)
                .first { $0.flavor == ParcelFlavor.indicRequest.rawValue }
                .flatMap { String(bytes: $0.body, encoding: .utf8) }
        }
    }

    static func serverCode(of body: () throws -> Void) -> Int? {
        do {
            try body()
            return nil
        } catch TeradataWireError.server(let code, _) {
            return code
        } catch {
            return nil
        }
    }
}

struct TeradataStatementKindTests {
    @Test(
        "Reads leave the transaction as it was",
        arguments: [
            "SELECT 1",
            "sel * from sales.t",
            "HELP SESSION",
            "SHOW TABLE sales.t",
            "EXPLAIN DELETE FROM sales.t",
            "(SELECT 1) UNION (SELECT 2)",
            "/* nightly */ SELECT 1",
            "-- nightly\nSELECT 1",
            "LOCKING ROW FOR ACCESS SELECT * FROM sales.t",
            "LOCK TABLE sales.t FOR READ OVERRIDE SELECT * FROM sales.t",
            "LOCKING TABLE a FOR ACCESS LOCKING TABLE b FOR ACCESS SELECT * FROM a, b",
            "WITH c (n) AS (SELECT 1) SELECT * FROM c",
        ]
    )
    func reads(statement: String) {
        #expect(TeradataStatementKind.kinds(in: statement) == [.read])
    }

    @Test(
        "Anything that is not a known read or transaction statement counts as a change",
        arguments: [
            "INSERT INTO sales.t VALUES (1)",
            "ins sales.t (1)",
            "UPDATE sales.t SET a = 1",
            "DELETE sales.t ALL",
            "MERGE INTO sales.t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a",
            "CREATE TABLE sales.t (a INTEGER)",
            "DATABASE sales",
            "SET SESSION DATEFORM = ANSIDATE",
            "CALL sales.p()",
            "EXEC sales.m",
            "BEGIN QUERY LOGGING ON ALL",
            "END LOGGING ON ALL ON TABLE sales.t",
            "USING (a INTEGER) INSERT INTO sales.t VALUES (:a)",
            "LOCKING TABLE sales.t FOR WRITE UPDATE sales.t SET a = 1",
            "LOCKING TABLE sales.t FOR WRITE",
            "WITH c (n) AS (SELECT 1) INSERT INTO sales.t SELECT n FROM c",
            "'not a statement'",
            "COLLECT STATISTICS COLUMN (a) ON sales.t",
            "SELECT AND CONSUME TOP 1 * FROM sales.q",
            "sel and consume top 1 * from sales.q",
        ]
    )
    func changes(statement: String) {
        #expect(TeradataStatementKind.kinds(in: statement) == [.change])
    }

    @Test("Transaction statements are told apart, in either spelling")
    func transactionStatements() {
        #expect(TeradataStatementKind.kinds(in: "BT") == [.begin])
        #expect(TeradataStatementKind.kinds(in: "begin transaction") == [.begin])
        #expect(TeradataStatementKind.kinds(in: "ET") == [.end])
        #expect(TeradataStatementKind.kinds(in: "END TRANSACTION") == [.end])
        #expect(TeradataStatementKind.kinds(in: "COMMIT") == [.commit])
        #expect(TeradataStatementKind.kinds(in: "COMMIT WORK") == [.commit])
        #expect(TeradataStatementKind.kinds(in: "ROLLBACK WORK") == [.rollback])
        #expect(TeradataStatementKind.kinds(in: "ABORT 'stopped by hand'") == [.rollback])
    }

    @Test("A request is split at each semicolon outside quotes and comments")
    func requestSplitting() {
        #expect(TeradataStatementKind.kinds(in: "INSERT INTO t VALUES (1); COMMIT;") == [.change, .commit])
        #expect(TeradataStatementKind.kinds(in: "SELECT 'a; COMMIT'") == [.read])
        #expect(TeradataStatementKind.kinds(in: "SELECT 'it''s; COMMIT' FROM t") == [.read])
        #expect(TeradataStatementKind.kinds(in: "SELECT \"COMMIT;\" FROM t") == [.read])
        #expect(TeradataStatementKind.kinds(in: "SELECT 1 -- ; COMMIT\n") == [.read])
        #expect(TeradataStatementKind.kinds(in: "/* ; COMMIT */ SELECT 1") == [.read])
        #expect(TeradataStatementKind.kinds(in: " ; ; ").isEmpty)
    }
}

struct TeradataTransactionTrackerTests {
    @Test("In ANSI a change opens the transaction, a read does not, and COMMIT closes it")
    func ansiChangesOpenTheTransaction() {
        var tracker = TeradataTransactionTracker(mode: .ansi)
        tracker.ran([.read])
        #expect(tracker.state == .idle)
        tracker.ran([.change])
        #expect(tracker.state == .open)
        tracker.ran([.read])
        #expect(tracker.state == .open)
        tracker.ran([.commit])
        #expect(tracker.state == .idle)
    }

    @Test("In ANSI a rollback's own failure answer closes the transaction and any other failure keeps it")
    func ansiFailures() {
        var tracker = TeradataTransactionTracker(mode: .ansi)
        tracker.ran([.change])
        tracker.failed([.change], code: 3_807)
        #expect(tracker.state == .open)
        tracker.failed([.change], code: 3_514)
        #expect(tracker.state == .open)
        tracker.failed([.rollback], code: 3_514)
        #expect(tracker.state == .idle)

        tracker.ran([.change])
        tracker.failed([.rollback], code: 3_513)
        #expect(tracker.state == .idle)

        tracker.ran([.change])
        tracker.failed([.read], code: TeradataConnection.userAbortCode)
        #expect(tracker.state == .idle)
    }

    @Test("A rollback that answered success had a condition that held nothing, so the transaction stays open")
    func conditionalRollbackKeepsTheTransaction() {
        var ansi = TeradataTransactionTracker(mode: .ansi)
        ansi.ran([.change, .rollback])
        #expect(ansi.state == .open)

        var tera = TeradataTransactionTracker(mode: .tera)
        tera.ran([.begin, .rollback])
        #expect(tera.state == .open)
    }

    @Test("In Teradata mode only an explicit transaction is open, and the outermost pair decides")
    func teradataModeTracksTheOutermostPair() {
        var tracker = TeradataTransactionTracker(mode: .tera)
        tracker.ran([.change])
        #expect(tracker.state == .idle)
        #expect(!tracker.abortRollsBackTransaction)
        tracker.ran([.begin])
        #expect(tracker.state == .open)
        #expect(tracker.abortRollsBackTransaction)
        tracker.ran([.begin])
        tracker.ran([.end])
        #expect(tracker.state == .open)
        tracker.ran([.end])
        #expect(tracker.state == .idle)
        tracker.ran([.end])
        #expect(tracker.state == .idle)
        tracker.ran([.begin])
        #expect(tracker.state == .open)
    }

    @Test("In Teradata mode any failure rolls the explicit transaction back")
    func teradataFailureEndsTheTransaction() {
        var tracker = TeradataTransactionTracker(mode: .tera)
        tracker.ran([.begin, .begin, .change])
        tracker.failed([.change], code: 3_706)
        #expect(tracker.state == .idle)
    }

    @Test("A session whose mode could not be read reports nothing it cannot know")
    func unresolvedModeIsUnknown() {
        var tracker = TeradataTransactionTracker(mode: .default)
        #expect(tracker.state == .unknown)
        tracker.ran([.begin])
        #expect(tracker.state == .unknown)
        #expect(tracker.abortRollsBackTransaction)
    }
}

struct TeradataSessionModeProbeTests {
    private static func result(_ cells: [(name: String, value: String)]) -> TeradataResultSet {
        TeradataResultSet(
            columns: cells.map { TeradataColumn(name: $0.name, typeCode: TeradataWire.varchar, dataLength: 64) },
            rows: [cells.map { .text($0.value) }],
            activityCount: 1
        )
    }

    @Test("HELP SESSION's Transaction Semantics column is found by its name, wherever it is")
    func helpSessionColumnByName() {
        let ansi = Self.result([("User Name", "DBC"), ("Transaction Semantics", "ANSI"), ("Current DateForm", "IntegerDate")])
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: ansi) == .ansi)

        let teradata = Self.result([("Transaction Semantics", "Teradata"), ("User Name", "ANSI")])
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: teradata) == .tera)

        let spelled = Self.result([("TRANSACTION_SEMANTICS", "teradata  ")])
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: spelled) == .tera)
    }

    @Test("A HELP SESSION answer without a known value says nothing")
    func helpSessionWithoutTheAnswer() {
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: Self.result([("User Name", "ANSI")])) == nil)
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: Self.result([("Transaction Semantics", "Other")])) == nil)
        let empty = TeradataResultSet(
            columns: [TeradataColumn(name: "Transaction Semantics", typeCode: TeradataWire.varchar, dataLength: 8)],
            rows: [],
            activityCount: 0
        )
        #expect(TeradataSessionModeProbe.mode(fromHelpSession: empty) == nil)
    }

    @Test("DBC.SessionInfoV codes the mode as A or T")
    func sessionInfoCodes() {
        #expect(TeradataSessionModeProbe.mode(fromSessionInfo: Self.result([("Transaction_Mode", "A")])) == .ansi)
        #expect(TeradataSessionModeProbe.mode(fromSessionInfo: Self.result([("Transaction_Mode", "T")])) == .tera)
        #expect(TeradataSessionModeProbe.mode(fromSessionInfo: Self.result([("Transaction_Mode", "D")])) == nil)
    }
}

struct TeradataSessionSetupTests {
    private static let ansiSession = TeradataWire.textRow([("User Name", "DBC"), ("Transaction Semantics", "ANSI")])

    @Test("DEFAULT asks HELP SESSION, and an ANSI session commits what its setup opened")
    func defaultReadsHelpSession() throws {
        let (connection, transport) = TeradataWire.connection(
            [Self.ansiSession, TeradataWire.finished, TeradataWire.finished], mode: .default, database: "sales"
        )

        try connection.prepareSession()

        #expect(try TeradataWire.sentSQL(transport) == [
            "HELP SESSION", TeradataSchemaQueries.setDatabase("sales"), "COMMIT WORK",
        ])
        #expect(connection.sessionTransactionMode == .ansi)
        #expect(connection.sessionModeSource == .helpSession)
        #expect(connection.transactionState == .idle)
    }

    @Test("A HELP SESSION the server refuses falls back to DBC.SessionInfoV")
    func refusedHelpSessionFallsBackToTheView() throws {
        let (connection, transport) = TeradataWire.connection(
            [TeradataWire.failure(code: 3_523), TeradataWire.textRow([("Transaction_Mode", "T")])], mode: .default
        )

        try connection.prepareSession()

        #expect(try TeradataWire.sentSQL(transport) == ["HELP SESSION", TeradataSessionModeProbe.sessionInfo])
        #expect(connection.sessionTransactionMode == .tera)
        #expect(connection.sessionModeSource == .sessionInfoView)
        #expect(connection.transactionState == .idle)
    }

    @Test("A HELP SESSION reply the decoder cannot read falls back to DBC.SessionInfoV")
    func unreadableHelpSessionFallsBackToTheView() throws {
        let unreadable = TeradataWire.reply([
            TeradataWire.prepInfoX([(605, 20, "Spool")]), Parcel(.record, body: [0x00, 0x01]), Parcel(.endRequest),
        ])
        let (connection, _) = TeradataWire.connection(
            [unreadable, TeradataWire.textRow([("Transaction_Mode", "A")]), TeradataWire.finished], mode: .default
        )

        try connection.prepareSession()

        #expect(connection.sessionTransactionMode == .ansi)
        #expect(connection.sessionModeSource == .sessionInfoView)
    }

    @Test("When neither read answers, the session keeps Teradata semantics and its state is unknown")
    func unresolvedModeKeepsTodaysBehaviour() throws {
        let (connection, transport) = TeradataWire.connection(
            [TeradataWire.failure(code: 3_523), TeradataWire.failure(code: 3_523), TeradataWire.finished], mode: .default
        )

        try connection.prepareSession()
        #expect(connection.sessionTransactionMode == .default)
        #expect(connection.sessionModeSource == .unresolved)
        #expect(connection.transactionState == .unknown)

        try connection.beginTransaction()
        #expect(try TeradataWire.sentSQL(transport).last == "BEGIN TRANSACTION")
    }

    @Test("An explicit mode is trusted without asking")
    func explicitModeIsTrusted() throws {
        let (ansi, ansiTransport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.finished], mode: .ansi, database: "sales"
        )
        try ansi.prepareSession()
        #expect(try TeradataWire.sentSQL(ansiTransport) == [TeradataSchemaQueries.setDatabase("sales"), "COMMIT WORK"])
        #expect(ansi.sessionModeSource == .configured)

        let (tera, teraTransport) = TeradataWire.connection([], mode: .tera)
        try tera.prepareSession()
        #expect(teraTransport.sent.isEmpty)
        #expect(tera.sessionTransactionMode == .tera)
        #expect(tera.transactionState == .idle)
    }
}

struct TeradataTransactionStatementTests {
    @Test("ANSI begins with nothing, commits with COMMIT WORK, and reports a change until then")
    func ansiTransaction() throws {
        let (connection, transport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.finished, TeradataWire.finished], mode: .ansi
        )

        try connection.beginTransaction()
        #expect(transport.sent.isEmpty)
        _ = try connection.execute("SELECT * FROM sales.t")
        #expect(connection.transactionState == .idle)
        _ = try connection.execute("UPDATE sales.t SET a = 1")
        #expect(connection.transactionState == .open)
        try connection.commitTransaction()

        #expect(try TeradataWire.sentSQL(transport) == ["SELECT * FROM sales.t", "UPDATE sales.t SET a = 1", "COMMIT WORK"])
        #expect(connection.transactionState == .idle)
    }

    @Test("Teradata mode begins with BEGIN TRANSACTION and commits with END TRANSACTION")
    func teradataTransaction() throws {
        let (connection, transport) = TeradataWire.connection([TeradataWire.finished, TeradataWire.finished], mode: .tera)

        try connection.beginTransaction()
        #expect(connection.transactionState == .open)
        try connection.commitTransaction()

        #expect(try TeradataWire.sentSQL(transport) == ["BEGIN TRANSACTION", "END TRANSACTION"])
        #expect(connection.transactionState == .idle)
    }

    @Test(
        "A rollback answered with 3513 or 3514 succeeded",
        arguments: [TeradataTransactionMode.ansi, .tera],
        [3_513, 3_514]
    )
    func rollbackAnswerIsSuccess(mode: TeradataTransactionMode, code: Int) throws {
        let (connection, transport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.failure(code: code, "User-generated transaction ABORT.")], mode: mode
        )
        _ = try connection.execute(mode == .ansi ? "DELETE FROM sales.t" : "BT")
        #expect(connection.transactionState == .open)

        try connection.rollbackTransaction()

        #expect(try TeradataWire.sentSQL(transport).last == (mode == .ansi ? "ROLLBACK WORK" : "ROLLBACK"))
        #expect(connection.transactionState == .idle)
    }

    @Test("Any other failure from a rollback still throws")
    func otherRollbackFailureThrows() {
        let (connection, _) = TeradataWire.connection([TeradataWire.failure(code: 2_631, "Transaction ABORTed due to deadlock.")], mode: .ansi)
        #expect(TeradataWire.serverCode { try connection.rollbackTransaction() } == 2_631)
    }

    @Test("The rollback answer code is success only for a rollback")
    func rollbackCodeFromAnotherStatementThrows() {
        let (connection, _) = TeradataWire.connection([TeradataWire.failure(code: 3_514)], mode: .ansi)
        #expect(TeradataWire.serverCode { _ = try connection.execute("UPDATE sales.t SET a = 1") } == 3_514)
    }

    @Test("In Teradata mode a failure inside BT ends the transaction")
    func teradataFailureInsideTransaction() throws {
        let (connection, _) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.failure(code: 3_706, "Syntax error")], mode: .tera
        )
        try connection.beginTransaction()
        #expect(TeradataWire.serverCode { _ = try connection.execute("INSRT INTO sales.t VALUES (1)") } == 3_706)
        #expect(connection.transactionState == .idle)
    }

    @Test("Stop inside BT reports that the server rolled the transaction back")
    func stopInsideExplicitTransactionRollsBack() throws {
        let aborted = TeradataWire.failure(code: TeradataConnection.userAbortCode, "The transaction was aborted by the user.")
        let (connection, transport) = TeradataWire.connection([TeradataWire.finished, aborted], mode: .tera)
        try connection.beginTransaction()
        transport.beforeReply[1] = { connection.cancel() }

        do {
            _ = try connection.execute("SELECT * FROM sales.orders CROSS JOIN sales.items")
            Issue.record("expected the Stop to throw")
        } catch TeradataWireError.rolledBackByStop {
            #expect(connection.transactionState == .idle)
        }
    }

    @Test("A database switch commits at once in ANSI and never joins an open transaction")
    func databaseSwitch() throws {
        let (ansi, ansiTransport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.finished, TeradataWire.finished], mode: .ansi
        )
        try ansi.switchDatabase(to: "sales")
        #expect(try TeradataWire.sentSQL(ansiTransport) == [TeradataSchemaQueries.setDatabase("sales"), "COMMIT WORK"])
        #expect(ansi.transactionState == .idle)

        _ = try ansi.execute("UPDATE sales.t SET a = 1")
        #expect(throws: TeradataWireError.self) { try ansi.switchDatabase(to: "hr") }
        #expect(try TeradataWire.sentSQL(ansiTransport).count == 3)

        let (tera, teraTransport) = TeradataWire.connection([TeradataWire.finished, TeradataWire.finished], mode: .tera)
        try tera.switchDatabase(to: "sales")
        try tera.beginTransaction()
        #expect(throws: TeradataWireError.self) { try tera.switchDatabase(to: "hr") }
        #expect(try TeradataWire.sentSQL(teraTransport) == [TeradataSchemaQueries.setDatabase("sales"), "BEGIN TRANSACTION"])
    }

    @Test("Inside an open transaction a switch to the database the session is on sends nothing")
    func switchToTheCurrentDatabaseInsideATransaction() throws {
        let (ansi, ansiTransport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.finished, TeradataWire.finished], mode: .ansi
        )
        try ansi.switchDatabase(to: "sales")
        _ = try ansi.execute("UPDATE sales.t SET a = 1")

        try ansi.switchDatabase(to: "SALES")

        #expect(try TeradataWire.sentSQL(ansiTransport) == [
            TeradataSchemaQueries.setDatabase("sales"), "COMMIT WORK", "UPDATE sales.t SET a = 1",
        ])
        #expect(ansi.transactionState == .open)

        let (tera, teraTransport) = TeradataWire.connection([TeradataWire.finished, TeradataWire.finished], mode: .tera)
        try tera.switchDatabase(to: "sales")
        try tera.beginTransaction()
        try tera.switchDatabase(to: "sales")
        #expect(try TeradataWire.sentSQL(teraTransport) == [TeradataSchemaQueries.setDatabase("sales"), "BEGIN TRANSACTION"])
    }

    @Test(
        "A request that moves the default database leaves the next switch inside a transaction refused",
        arguments: ["DATABASE hr", "SET SESSION DATABASE hr", "SS DATABASE hr", "EXEC sales.refresh", "CALL sales.load()"]
    )
    func userMovedDatabaseIsNotTrusted(_ statement: String) throws {
        let (ansi, ansiTransport) = TeradataWire.connection(
            [TeradataWire.finished, TeradataWire.finished, TeradataWire.finished], mode: .ansi
        )
        try ansi.switchDatabase(to: "sales")
        _ = try ansi.execute(statement)

        #expect(throws: TeradataWireError.self) { try ansi.switchDatabase(to: "sales") }
        #expect(try TeradataWire.sentSQL(ansiTransport).count == 3)
    }
}

struct TeradataDefaultDatabaseStatementTests {
    @Test(
        "Statements that can move the default database",
        arguments: [
            ("DATABASE hr", true),
            ("database \"hr\";", true),
            ("SET SESSION DATABASE hr", true),
            ("ss database hr", true),
            ("EXEC sales.refresh", true),
            ("CALL sales.load()", true),
            ("SELECT 1; DATABASE hr", true),
            ("SET SESSION DATEFORM = ANSIDATE", false),
            ("SELECT DATABASE", false),
            ("CREATE DATABASE hr FROM dbc AS PERM = 0", false),
            ("COMMENT ON DATABASE hr AS 'x'", false),
        ]
    )
    func mayMoveDefaultDatabase(_ request: String, _ moves: Bool) {
        #expect(TeradataStatementKind.mayMoveDefaultDatabase(request) == moves)
    }
}

struct TeradataUnreadableColumnTests {
    private static func decodingError(type: UInt16, name: String) -> TeradataWireError? {
        let reply = TeradataWire.reply([
            TeradataWire.prepInfoX([(type, 20, name)]), Parcel(.record, body: [0x00, 0x01]), Parcel(.endRequest),
        ])
        let (connection, _) = TeradataWire.connection([reply], mode: .tera)
        do {
            _ = try connection.execute("SELECT \(name) FROM sales.t")
            return nil
        } catch {
            return error as? TeradataWireError
        }
    }

    @Test("A NUMBER column names itself and says to cast it to DECIMAL or VARCHAR")
    func numberColumn() throws {
        let error = try #require(Self.decodingError(type: 605, name: "amount"))
        guard case .unreadableColumn(let name, let typeCode) = error else {
            Issue.record("expected an unreadable column, got \(error)")
            return
        }
        #expect(name == "amount")
        #expect(typeCode == 605)
        #expect(error.description.contains("\"amount\""))
        #expect(error.description.contains("NUMBER"))
        #expect(error.description.contains("CAST it to DECIMAL or VARCHAR"))
    }

    @Test("Another unreadable type names itself and says to cast it to VARCHAR")
    func periodColumn() throws {
        let error = try #require(Self.decodingError(type: 833, name: "span"))
        #expect(error.description.contains("\"span\""))
        #expect(error.description.contains("PERIOD(DATE)"))
        #expect(error.description.contains("CAST it to VARCHAR"))
        #expect(!error.description.contains("DECIMAL"))
    }

    @Test("A type code with no known name is given by its number")
    func unknownTypeCode() throws {
        let error = try #require(Self.decodingError(type: 1_234, name: "odd"))
        #expect(error.description.contains("type 1234"))
    }
}
