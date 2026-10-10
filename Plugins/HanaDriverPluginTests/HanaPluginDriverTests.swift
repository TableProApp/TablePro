import Foundation
import TableProPluginKit
import XCTest

final class HanaPluginDriverTests: XCTestCase {
    func testPluginDeclaresTheHanaTransportAndScope() {
        XCTAssertEqual(HanaPlugin.databaseTypeId, "SAP HANA")
        XCTAssertEqual(HanaPlugin.defaultPort, 443)
        XCTAssertTrue(HanaPlugin.isDownloadable)
        XCTAssertTrue(HanaPlugin.supportsSSL)
        XCTAssertFalse(HanaPlugin.supportsSSH)
        XCTAssertTrue(HanaPlugin.supportsForeignKeys)
        XCTAssertFalse(HanaPlugin.supportsSchemaEditing)
        XCTAssertFalse(HanaPlugin.supportsAddColumn)
        XCTAssertFalse(HanaPlugin.supportsDropIndex)
        XCTAssertTrue(HanaPlugin.supportsSchemaSwitching)
        XCTAssertFalse(HanaPlugin.supportsDatabaseSwitching)
        XCTAssertEqual(HanaPlugin.urlSchemes, ["hdb"])
        XCTAssertTrue(HanaPlugin.additionalConnectionFields.contains { $0.id == HanaMetadata.tlsServerNameField })
    }

    func testExplainVariantUsesTheIndentedPlanFormat() throws {
        let variant = try XCTUnwrap(HanaPlugin.explainVariants.first)
        XCTAssertEqual(HanaPlugin.explainVariants.count, 1)
        XCTAssertEqual(variant.id, "plan")
        XCTAssertEqual(variant.sqlPrefix, "EXPLAIN PLAN FOR")
        XCTAssertEqual(variant.format, .indentedText)
        XCTAssertEqual(
            HanaExplainStatement.explainedStatement(in: "\(variant.sqlPrefix) SELECT 1 FROM DUMMY"),
            "SELECT 1 FROM DUMMY"
        )
    }

    func testDialectMatchesWhatHanaAccepts() throws {
        let dialect = try XCTUnwrap(HanaPlugin.sqlDialect)
        XCTAssertEqual(dialect.identifierQuote, "\"")
        XCTAssertEqual(dialect.regexSyntax, .unsupported)
        XCTAssertEqual(dialect.booleanLiteralStyle, .truefalse)
        XCTAssertEqual(dialect.likeEscapeStyle, .explicit)
        XCTAssertEqual(dialect.paginationStyle, .limit)
        XCTAssertEqual(dialect.autoLimitStyle, .limit)
        XCTAssertEqual(dialect.caseSensitivityStyle, .caseFoldFunction)
        XCTAssertEqual(dialect.caseFoldFunction, "LOWER")
        XCTAssertFalse(dialect.requiresBackslashEscaping)
        XCTAssertNil(dialect.textCastTypeName)
        XCTAssertTrue(dialect.functionNamesAreCaseInsensitive)
        XCTAssertEqual(dialect.lexicalFeatures, [.dollarAndHashInIdentifiers])
        XCTAssertEqual(HanaPlugin.caseSensitivityStyle, .caseFoldFunction)
    }

    func testExplainCompletionIsAPlainPlanStatement() throws {
        let completion = try XCTUnwrap(HanaPlugin.statementCompletions.first { $0.label == "EXPLAIN PLAN" })
        XCTAssertTrue(completion.insertText.hasPrefix("EXPLAIN PLAN FOR SELECT"))
        XCTAssertNotNil(HanaExplainStatement.explainedStatement(in: completion.insertText))
    }

    func testDriverQuotingSurvivesCombiningMarks() {
        let driver = HanaPluginDriver(config: config(), session: HanaFakeSession())
        XCTAssertEqual(driver.quoteIdentifier("a\"\u{0301}"), "\"a\"\"\u{0301}\"")
        XCTAssertEqual(driver.escapeStringLiteral("a'\u{0301}\0"), "a''\u{0301}")
    }

    func testObjectCommentStatementResolvesTheSchemaWithoutThrowing() {
        let configured = HanaPluginDriver(config: config(database: "APP"), session: HanaFakeSession())
        XCTAssertEqual(
            configured.objectCommentStatement(name: "ORDERS", objectType: "TABLE", schema: nil, comment: "x"),
            "COMMENT ON TABLE \"APP\".\"ORDERS\" IS N'x'"
        )
        XCTAssertEqual(
            configured.objectCommentStatement(name: "V", objectType: "VIEW", schema: "SALES", comment: nil),
            "COMMENT ON VIEW \"SALES\".\"V\" IS NULL"
        )
        XCTAssertNil(configured.objectCommentStatement(name: "t", objectType: "SEQUENCE", schema: "s", comment: nil))

        let unscoped = HanaPluginDriver(config: config(database: ""), session: HanaFakeSession())
        XCTAssertEqual(
            unscoped.objectCommentStatement(name: "T", objectType: "TABLE", schema: nil, comment: nil),
            "COMMENT ON TABLE \"T\" IS NULL"
        )
    }

    func testCreateViewTemplateIsACreateViewSkeleton() throws {
        let driver = HanaPluginDriver(config: config(), session: HanaFakeSession())
        let template = try XCTUnwrap(driver.createViewTemplate())
        XCTAssertTrue(template.hasPrefix("CREATE VIEW view_name AS\nSELECT"))
    }

    func testConnectSendsTheConfiguredSettingsAndKeepsTheConfiguredSchema() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(
            config: config(
                database: " APP ",
                ssl: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: " /tmp/ca.pem "),
                additionalFields: [HanaMetadata.tlsServerNameField: "real.example.com"]
            ),
            session: session
        )

        try await driver.connect()

        let sent = try XCTUnwrap(session.connects.first)
        XCTAssertEqual(sent.host, "hana.example")
        XCTAssertEqual(sent.schema, "APP")
        XCTAssertEqual(sent.tlsMode, .verifyIdentity)
        XCTAssertEqual(sent.tlsServerName, "real.example.com")
        XCTAssertEqual(sent.caCertificatePath, "/tmp/ca.pem")
        XCTAssertEqual(sent.connectTimeoutSeconds, HanaConnectConfiguration.defaultConnectTimeoutSeconds)
        XCTAssertEqual(driver.currentSchema, "APP")
        XCTAssertEqual(driver.serverVersion, "4.00.000.00.1234567890")
    }

    func testConnectSendsTheRemainingMillisecondBudget() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(
            config: config(additionalFields: [
                "connectTimeoutMilliseconds": "1250",
                "connectTimeoutSeconds": "30"
            ]),
            session: session
        )

        try await driver.connect()

        XCTAssertEqual(try XCTUnwrap(session.connects.first).connectTimeoutSeconds, 1.25)
    }

    func testConnectFallsBackToConfiguredSecondsForAnOlderHost() throws {
        let configuration = try HanaConnectionSettings.configuration(from: config(
            additionalFields: ["connectTimeoutSeconds": "2.5"]
        ))

        XCTAssertEqual(configuration.connectTimeoutSeconds, 2.5)
    }

    func testConnectAdoptsTheServerSchemaWhenNoneIsConfigured() async throws {
        let driver = HanaPluginDriver(config: config(database: ""), session: HanaFakeSession())

        try await driver.connect()

        XCTAssertEqual(driver.currentSchema, "DBADMIN")
    }

    func testDisconnectKeepsTheConfiguredSchema() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)
        try await driver.connect()
        try await driver.switchSchema(to: "OTHER")

        driver.disconnect()

        XCTAssertEqual(session.disconnectCount, 1)
        XCTAssertEqual(driver.currentSchema, "APP")
        XCTAssertNil(driver.serverVersion)
    }

    func testDisabledTLSSendsNoCertificatePaths() throws {
        let configuration = try HanaConnectionSettings.configuration(from: config(
            ssl: SSLConfiguration(
                mode: .disabled,
                caCertificatePath: "/ca.pem",
                clientCertificatePath: "/cert.pem",
                clientKeyPath: "/key.pem"
            ),
            additionalFields: [HanaMetadata.tlsServerNameField: "other"]
        ))

        XCTAssertEqual(configuration.tlsMode, .disabled)
        XCTAssertEqual(configuration.caCertificatePath, "")
        XCTAssertEqual(configuration.clientCertificatePath, "")
        XCTAssertEqual(configuration.clientKeyPath, "")
        XCTAssertEqual(configuration.tlsServerName, "")
    }

    func testSettingsAreValidatedBeforeTheBridgeIsCalled() {
        let invalid = [
            config(host: "  "),
            config(port: 0),
            config(port: 70_000),
            config(username: ""),
            config(ssl: SSLConfiguration(mode: .required, clientCertificatePath: "/cert.pem")),
            config(ssl: SSLConfiguration(mode: .required, clientKeyPath: "/key.pem"))
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try HanaConnectionSettings.configuration(from: candidate)) { error in
                XCTAssertEqual((error as? HanaError)?.kind, .configuration)
            }
        }
        XCTAssertNoThrow(try HanaConnectionSettings.configuration(from: config(
            ssl: SSLConfiguration(mode: .required, clientCertificatePath: "/cert.pem", clientKeyPath: "/key.pem")
        )))
    }

    func testConnectMapsBridgeFailures() async {
        let session = HanaFakeSession()
        session.connectWith(.failure(HanaBridgeFailure(kind: .tls, code: 1, message: "x509")))
        let driver = HanaPluginDriver(config: config(), session: session)

        do {
            try await driver.connect()
            XCTFail("connect should fail")
        } catch {
            guard case .untrustedCertificate = error as? SSLHandshakeError else {
                return XCTFail("expected an untrusted certificate error, got \(error)")
            }
        }
    }

    func testUserQueriesBindParametersThroughTheBridge() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)

        _ = try await driver.executeUserQuery(
            query: "UPDATE T SET A = ? WHERE ID = ?",
            rowCap: 200,
            parameters: [.text("x"), .bytes(Data([1]))]
        )
        _ = try await driver.executeParameterized(query: "DELETE FROM T WHERE ID = ?", parameters: [.null])
        _ = try await driver.executeUserQuery(query: "SELECT 1 FROM DUMMY", rowCap: nil, parameters: [])

        XCTAssertEqual(session.executed, [
            HanaFakeSession.ExecutedStatement(
                sql: "UPDATE T SET A = ? WHERE ID = ?",
                parameters: [.text("x"), .bytes(Data([1]))],
                rowCap: 200
            ),
            HanaFakeSession.ExecutedStatement(
                sql: "DELETE FROM T WHERE ID = ?",
                parameters: [.null],
                rowCap: PluginRowLimits.emergencyMax
            ),
            HanaFakeSession.ExecutedStatement(
                sql: "SELECT 1 FROM DUMMY",
                parameters: nil,
                rowCap: PluginRowLimits.emergencyMax
            )
        ])
    }

    func testRowCapIsBoundedByTheEmergencyLimit() {
        XCTAssertEqual(HanaPluginDriver.fetchLimit(nil), PluginRowLimits.emergencyMax)
        XCTAssertEqual(HanaPluginDriver.fetchLimit(0), PluginRowLimits.emergencyMax)
        XCTAssertEqual(HanaPluginDriver.fetchLimit(500), 500)
        XCTAssertEqual(HanaPluginDriver.fetchLimit(PluginRowLimits.emergencyMax + 1), PluginRowLimits.emergencyMax)
    }

    func testExplainRunsTheBridgePlanOperationWithTheInnerStatement() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(["QUERY PLAN"], [[.text("COLUMN SEARCH")], [.text("  COLUMN TABLE [table APP.T]")]]))
        let driver = HanaPluginDriver(config: config(), session: session)

        let result = try await driver.executeUserQuery(
            query: "EXPLAIN PLAN FOR SELECT * FROM \"APP\".\"T\"",
            rowCap: nil,
            parameters: nil
        )

        XCTAssertEqual(session.explained, ["SELECT * FROM \"APP\".\"T\""])
        XCTAssertTrue(session.executed.isEmpty)
        XCTAssertEqual(result.columns, ["QUERY PLAN"])
        XCTAssertEqual(result.rows.count, 2)
    }

    func testExplainWithParametersIsExecutedAsTyped() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)

        _ = try await driver.executeUserQuery(query: "EXPLAIN PLAN FOR SELECT ?", rowCap: nil, parameters: [.text("1")])

        XCTAssertTrue(session.explained.isEmpty)
        XCTAssertEqual(session.executed.map(\.sql), ["EXPLAIN PLAN FOR SELECT ?"])
    }

    func testStopDuringAStatementReportsACancellation() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)
        session.runDuringStatement { [weak driver] in
            try? driver?.cancelQuery()
        }
        session.fail(HanaBridgeFailure(kind: .cancelled))

        do {
            _ = try await driver.executeUserQuery(query: "SELECT * FROM BIG", rowCap: nil, parameters: nil)
            XCTFail("the statement should report a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(session.cancelled.map { ObjectIdentifier($0) }, session.slots.map { ObjectIdentifier($0) })
        XCTAssertEqual(session.cancelled.count, 1)
    }

    func testCancellationNobodyAskedForIsAnError() async {
        let session = HanaFakeSession()
        session.fail(HanaBridgeFailure(kind: .cancelled))
        let driver = HanaPluginDriver(config: config(), session: session)

        do {
            _ = try await driver.executeUserQuery(query: "SELECT 1 FROM DUMMY", rowCap: nil, parameters: nil)
            XCTFail("the statement should fail")
        } catch {
            XCTAssertEqual((error as? HanaError)?.kind, .cancelled, "got \(error)")
        }
    }

    func testAStopForAnEarlierStatementDoesNotCancelTheNextOne() async {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)
        _ = try? await driver.executeUserQuery(query: "SELECT 1 FROM DUMMY", rowCap: nil, parameters: nil)
        try? driver.cancelQuery()
        session.fail(HanaBridgeFailure(kind: .cancelled))

        do {
            _ = try await driver.executeUserQuery(query: "SELECT 2 FROM DUMMY", rowCap: nil, parameters: nil)
            XCTFail("the statement should fail")
        } catch {
            XCTAssertEqual((error as? HanaError)?.kind, .cancelled, "got \(error)")
        }
        XCTAssertTrue(session.cancelled.isEmpty)
    }

    func testStopCancelsTheSlotOfTheQueryThatIsRunning() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)
        let hold = session.hold(sql: "SELECT * FROM BIG")
        let run = Task { try await driver.executeUserQuery(query: "SELECT * FROM BIG", rowCap: nil, parameters: nil) }
        let slot = await hold.arrival()

        try driver.cancelQuery()

        XCTAssertEqual(session.cancelled.map { ObjectIdentifier($0) }, [ObjectIdentifier(slot)])
        XCTAssertTrue(slot.isCancelled)
        hold.release()
        do {
            _ = try await run.value
            XCTFail("the statement should report a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testStopWithNoQueryRunningCancelsNoSlot() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)

        try driver.cancelQuery()
        _ = try await driver.executeUserQuery(query: "SELECT 1 FROM DUMMY", rowCap: nil, parameters: nil)
        try driver.cancelQuery()

        XCTAssertTrue(session.cancelled.isEmpty)
        let slot = try XCTUnwrap(session.slots.first)
        XCTAssertEqual(session.slots.count, 1)
        XCTAssertFalse(slot.isCancelled)
    }

    func testAStopDeliveredAfterItsQueryFinishedLeavesTheNextQuerysSlotAlone() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)
        let first = session.hold(sql: "UPDATE A SET X = 1")
        let second = session.hold(sql: "UPDATE B SET X = 1")
        let delivery = session.holdCancels()
        let firstRun = Task {
            try await driver.executeUserQuery(query: "UPDATE A SET X = 1", rowCap: nil, parameters: nil)
        }
        let firstSlot = await first.arrival()

        let stopReturned = HanaLatch()
        DispatchQueue.global().async {
            try? driver.cancelQuery()
            stopReturned.open()
        }
        let stoppedSlot = await delivery.arrival()
        first.release()
        _ = try await firstRun.value
        let secondRun = Task {
            try await driver.executeUserQuery(query: "UPDATE B SET X = 1", rowCap: nil, parameters: nil)
        }
        let secondSlot = await second.arrival()
        delivery.release()
        await stopReturned.wait()
        second.release()

        _ = try await secondRun.value
        XCTAssertIdentical(stoppedSlot, firstSlot)
        XCTAssertNotIdentical(secondSlot, firstSlot)
        XCTAssertFalse(secondSlot.isCancelled)
        XCTAssertEqual(session.cancelled.map { ObjectIdentifier($0) }, [ObjectIdentifier(firstSlot)])
    }

    func testStopWhileAQueryWaitsBehindAPingStopsTheQueryAndNotThePing() async throws {
        let bridge = HanaFakeBridge()
        let queue = HanaRecordingQueue()
        let driver = HanaPluginDriver(config: config(), session: HanaConnection(bridge: bridge, queue: queue))
        try await driver.connect()
        let pingHold = bridge.holdPing()
        let ping = Task { try await driver.ping() }
        let pingTicket = await pingHold.arrival()
        let query = Task { try await driver.executeUserQuery(query: "SELECT * FROM BIG", rowCap: nil, parameters: nil) }
        await queue.submissions(reaching: 4)

        try driver.cancelQuery()

        let queryTicket = HanaOperationTicket(session: pingTicket.session, operation: pingTicket.operation + 1)
        XCTAssertEqual(bridge.cancels, [queryTicket])
        pingHold.release()
        try await ping.value
        do {
            _ = try await query.value
            XCTFail("the query queued behind the ping should report a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(bridge.pings, [pingTicket])
        XCTAssertTrue(bridge.statements.isEmpty)
    }

    func testStopWithNoQueryInFlightLeavesARunningPingAlone() async throws {
        let bridge = HanaFakeBridge()
        let driver = HanaPluginDriver(config: config(), session: HanaConnection(bridge: bridge))
        try await driver.connect()
        let hold = bridge.holdPing()
        let ping = Task { try await driver.ping() }
        _ = await hold.arrival()

        try driver.cancelQuery()

        XCTAssertTrue(bridge.cancels.isEmpty)
        hold.release()
        try await ping.value
    }

    func testStopDuringAQueryReachesTheBridgeBeforeCancelQueryReturns() async throws {
        let bridge = HanaFakeBridge()
        let driver = HanaPluginDriver(config: config(), session: HanaConnection(bridge: bridge))
        try await driver.connect()
        let hold = bridge.hold(sql: "SELECT * FROM BIG")
        let run = Task { try await driver.executeUserQuery(query: "SELECT * FROM BIG", rowCap: nil, parameters: nil) }
        let ticket = await hold.arrival()

        try driver.cancelQuery()

        XCTAssertEqual(bridge.cancels, [ticket])
        hold.release()
        do {
            _ = try await run.value
            XCTFail("the statement should report a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testAStatementThatSucceededOnASessionLostReturnsItsResultAndReportsTheLoss() async throws {
        let bridge = HanaFakeBridge()
        let lost = HanaBridgeJSON.envelope(columns: ["ID"], rows: [["7"]], sessionLost: true)
        bridge.respond(to: "SELECT ID FROM T", with: lost)
        let driver = HanaPluginDriver(config: config(), session: HanaConnection(bridge: bridge))
        try await driver.connect()

        let result = try await driver.executeUserQuery(query: "SELECT ID FROM T", rowCap: nil, parameters: nil)

        XCTAssertEqual(result.columns, ["ID"])
        XCTAssertEqual(result.rows, [[.text("7")]])
        XCTAssertTrue(driver.hasLostConnection)
    }

    func testServerErrorsAreMappedWithTheirCode() async {
        let session = HanaFakeSession()
        session.fail(HanaBridgeFailure(kind: .server, code: 259, message: "invalid table name"))
        let driver = HanaPluginDriver(config: config(), session: session)

        do {
            _ = try await driver.execute(query: "SELECT * FROM MISSING")
            XCTFail("the statement should fail")
        } catch {
            XCTAssertEqual((error as? HanaError)?.pluginErrorCode, 259, "got \(error)")
        }
    }

    func testTimeoutAndLostConnectionReachTheSession() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)

        XCTAssertFalse(driver.hasLostConnection)
        session.markConnectionLost()
        XCTAssertTrue(driver.hasLostConnection)

        try await driver.applyQueryTimeout(45)
        XCTAssertEqual(session.timeout, 45)
    }

    func testSwitchSchemaRunsSetSchemaWithTheExactQuotedName() async throws {
        let session = HanaFakeSession()
        let driver = HanaPluginDriver(config: config(), session: session)

        try await driver.switchSchema(to: "Mixed \"Case\"")

        XCTAssertEqual(session.executed.map(\.sql), ["SET SCHEMA \"Mixed \"\"Case\"\"\""])
        XCTAssertEqual(driver.currentSchema, "Mixed \"Case\"")
        do {
            try await driver.switchSchema(to: "  ")
            XCTFail("an empty schema name should be refused")
        } catch {
            XCTAssertEqual((error as? HanaError)?.kind, .configuration)
        }
    }

    func testFetchTablesAndDatabasesReadTheCatalogForTheCurrentSchema() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(
            ["TABLE_NAME", "OBJECT_TYPE", "COMMENTS"],
            [[.text("ORDERS"), .text("TABLE"), .null], [.text("V1"), .text("VIEW"), .text("A view")]]
        ))
        session.respond(HanaEnvelopes.rows(["SCHEMA_NAME"], [[.text("APP")], [.text("SYS")]]))
        session.respond(HanaEnvelopes.rows(["COUNT(*)"], [[.text("12")]]))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let tables = try await driver.fetchTables(schema: nil)
        let databases = try await driver.fetchDatabases()
        let metadata = try await driver.fetchDatabaseMetadata("SYS")

        XCTAssertEqual(tables.map(\.name), ["ORDERS", "V1"])
        XCTAssertEqual(tables.map(\.type), ["TABLE", "VIEW"])
        XCTAssertEqual(databases, ["APP", "SYS"])
        XCTAssertEqual(metadata.tableCount, 12)
        XCTAssertTrue(metadata.isSystemDatabase)
        XCTAssertEqual(session.executed.map(\.sql), [
            HanaCatalogQueries.tables(schema: "APP"),
            HanaCatalogQueries.schemas,
            HanaCatalogQueries.tableCount(schema: "SYS")
        ])
    }

    func testBulkColumnFetchIsOneQuery() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(
            Array(repeating: "C", count: 11),
            [
                [.text("A"), .text("ID"), .text("INTEGER"), .null, .null, .text("FALSE"), .null, .null, .null, .null,
                 .text("1")],
                [.text("B"), .text("ID"), .text("INTEGER"), .null, .null, .text("TRUE"), .null, .null, .null, .null,
                 .null]
            ]
        ))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let columns = try await driver.fetchAllColumns(schema: "APP")

        XCTAssertTrue(driver.providesBulkColumnFetch)
        XCTAssertEqual(session.executed.map(\.sql), [HanaCatalogQueries.columns(schema: "APP", table: nil)])
        XCTAssertEqual(columns["A"]?.first?.isPrimaryKey, true)
        XCTAssertEqual(columns["B"]?.first?.isPrimaryKey, false)
    }

    func testTableDDLComesFromTheCatalog() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(["IS_COLUMN_TABLE"], [[.text("TRUE")]]))
        session.respond(HanaEnvelopes.rows(
            Array(repeating: "C", count: 11),
            [[.text("T"), .text("ID"), .text("INTEGER"), .null, .null, .text("FALSE"), .null, .null, .null, .null,
              .text("1")]]
        ))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let ddl = try await driver.fetchTableDDL(table: "T", schema: nil)

        XCTAssertEqual(ddl, "CREATE COLUMN TABLE \"APP\".\"T\" (\n    \"ID\" INTEGER NOT NULL,\n    PRIMARY KEY (\"ID\")\n);")
    }

    func testTableDDLForAMissingTableIsAnError() async {
        let driver = HanaPluginDriver(config: config(database: "APP"), session: HanaFakeSession())

        do {
            _ = try await driver.fetchTableDDL(table: "MISSING", schema: nil)
            XCTFail("a missing table should fail")
        } catch {
            XCTAssertEqual((error as? HanaError)?.kind, .missingObject, "got \(error)")
        }
    }

    func testViewDefinitionIsACreateViewStatement() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(["DEFINITION"], [[.text("SELECT * FROM \"APP\".\"T\"")]]))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let definition = try await driver.fetchViewDefinition(view: "V", schema: nil)

        XCTAssertEqual(definition, "CREATE VIEW \"APP\".\"V\" AS\nSELECT * FROM \"APP\".\"T\"")
    }

    func testTableMetadataFallsBackToTheViewComment() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(["TABLE_TYPE", "COMMENTS", "RECORD_COUNT", "TABLE_SIZE"], []))
        session.respond(HanaEnvelopes.rows(["COMMENTS"], [[.text("Orders view")]]))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let metadata = try await driver.fetchTableMetadata(table: "V", schema: nil)

        XCTAssertEqual(metadata.comment, "Orders view")
        XCTAssertNil(metadata.rowCount)
    }

    func testApproximateRowCountReadsTheMonitoringView() async throws {
        let session = HanaFakeSession()
        session.respond(HanaEnvelopes.rows(["RECORD_COUNT"], [[.text("98765")]]))
        let driver = HanaPluginDriver(config: config(database: "APP"), session: session)

        let count = try await driver.fetchApproximateRowCount(table: "T", schema: "APP")

        XCTAssertEqual(count, 98_765)
        XCTAssertEqual(session.executed.map(\.sql), [HanaCatalogQueries.approximateRowCount(schema: "APP", table: "T")])
    }

    func testCatalogReadsNeedASchema() async {
        let driver = HanaPluginDriver(config: config(database: ""), session: HanaFakeSession())

        do {
            _ = try await driver.fetchTables(schema: nil)
            XCTFail("a catalog read without a schema should fail")
        } catch {
            XCTAssertEqual((error as? HanaError)?.kind, .configuration, "got \(error)")
        }
    }

    private func config(
        host: String = "hana.example",
        port: Int = 443,
        username: String = "DBADMIN",
        database: String = "APP",
        ssl: SSLConfiguration = SSLConfiguration(mode: .verifyIdentity),
        additionalFields: [String: String] = [:]
    ) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host,
            port: port,
            username: username,
            password: "test-only",
            database: database,
            ssl: ssl,
            additionalFields: additionalFields
        )
    }
}
