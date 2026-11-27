import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

private actor CatalogServer {
    private(set) var sent: [String] = []
    private var answers: [[[PluginCellValue]]]

    init(answers: [[[PluginCellValue]]] = []) {
        self.answers = answers
    }

    func answer(_ sql: String) -> PluginQueryResult {
        sent.append(sql)
        let rows = answers.isEmpty ? [] : answers.removeFirst()
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: rows, rowsAffected: 0, executionTime: 0)
    }
}

private final class FootprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var footprint = MySQLSessionFootprint()

    func adjust(_ change: (inout MySQLSessionFootprint) -> Void) {
        lock.withLock { change(&footprint) }
    }

    var heldSessionScopes: Int {
        lock.withLock { footprint.heldSessionScopes }
    }
}

private func makeCatalog(
    _ server: CatalogServer,
    flavor: MySQLServerFlavor = .mysql,
    banner: String? = "8.0.36",
    activeDatabase: String = "shop",
    exactSchema: Bool = false
) -> MySQLExportCatalog {
    MySQLExportCatalog(
        banner: banner,
        flavor: flavor,
        activeDatabase: activeDatabase,
        quote: { mysqlQuoteIdentifier($0) },
        run: { await server.answer($0) },
        schemaNamesAreCaseSensitive: { exactSchema },
        settlesBlindness: { _ in false }
    )
}

struct MySQLExportCatalogTests {
    @Test("Routines are listed, then their parameters read once, and keep the signature as identity")
    func routinesReadListThenParameters() async throws {
        let server = CatalogServer(answers: [
            [
                ["total", "FUNCTION", "decimal(10,2)", "READS SQL DATA", "YES", "DEFINER", "root@%", "shop"],
                ["cleanup", "PROCEDURE", nil, "", "NO", "INVOKER", "", "shop"],
            ],
            [
                ["shop", "FUNCTION", "total", nil, "order_id", "int"],
                ["shop", "PROCEDURE", "cleanup", "IN", "days", "int"],
            ],
        ])

        let routines = try await makeCatalog(server, exactSchema: true).routines(schema: nil)

        #expect(await server.sent == [
            MySQLObjectQueries.routineList(schema: "shop", exactSchema: true),
            MySQLObjectQueries.routineParameters(schema: "shop", exactSchema: true),
        ])
        #expect(routines.map(\.name) == ["total", "cleanup"])
        #expect(routines.map(\.kind) == [.function, .procedure])
        #expect(routines[0].returnType == "decimal(10,2)")
        #expect(routines[1].returnType == nil)
        #expect(routines[0].argumentSignature == "(order_id int)")
        #expect(routines[1].argumentSignature == "(IN days int)")
        #expect(routines[0].attributes.map(\.label) == ["Data Access", "Deterministic", "Security", "Definer"])
        #expect(routines[1].attributes.map(\.label) == ["Deterministic", "Security"])
    }

    @Test("A database with no routines reads no parameters")
    func noRoutinesNoParameterRead() async throws {
        let server = CatalogServer()
        let routines = try await makeCatalog(server).routines(schema: "app")
        #expect(routines.isEmpty)
        #expect(await server.sent == [MySQLObjectQueries.routineList(schema: "app", exactSchema: false)])
    }

    @Test("A flavor without MySQL object catalogs lists no routines, triggers or events and sends nothing")
    func databendSendsNothing() async throws {
        let server = CatalogServer()
        let catalog = makeCatalog(server, flavor: .databend)
        #expect(try await catalog.routines(schema: nil).isEmpty)
        #expect(try await catalog.allTriggers(schema: nil).isEmpty)
        #expect(try await catalog.events(schema: nil).isEmpty)
        #expect(await server.sent.isEmpty)
    }

    @Test("A NULL routine body is reported as a missing privilege, not a missing routine")
    func nullRoutineBodyIsPrivilege() async throws {
        let server = CatalogServer(answers: [[["cleanup", "", nil]]])
        let routine = PluginRoutineInfo(name: "cleanup", kind: .procedure, schema: "app")
        await #expect(throws: PluginObjectSourceError.self) {
            try await makeCatalog(server).routineDDL(routine)
        }
        #expect(await server.sent == ["SHOW CREATE PROCEDURE `app`.`cleanup`"])
    }

    @Test("Table DDL is the second column of SHOW CREATE TABLE, ended with one semicolon")
    func tableDDL() async throws {
        let server = CatalogServer(answers: [
            [["orders", "CREATE TABLE `orders` (`id` int)"]],
            [["orders", "CREATE TABLE `orders` (`id` int);"]],
            [],
        ])
        let catalog = makeCatalog(server)
        #expect(try await catalog.tableDDL(table: "orders", schema: nil) == "CREATE TABLE `orders` (`id` int);")
        #expect(try await catalog.tableDDL(table: "orders", schema: "app") == "CREATE TABLE `orders` (`id` int);")
        #expect(try await catalog.tableDDL(table: "gone", schema: nil) == nil)
        #expect(await server.sent == [
            "SHOW CREATE TABLE `shop`.`orders`",
            "SHOW CREATE TABLE `app`.`orders`",
            "SHOW CREATE TABLE `shop`.`gone`",
        ])
    }

    @Test("With no database selected the DDL read names the table alone")
    func unqualifiedWithoutDatabase() async throws {
        let server = CatalogServer()
        _ = try await makeCatalog(server, activeDatabase: "").tableDDL(table: "t", schema: nil)
        #expect(await server.sent == ["SHOW CREATE TABLE `t`"])
    }

    @Test("A view reads SHOW CREATE VIEW, and StarRocks reads SHOW CREATE TABLE")
    func viewDefinition() async throws {
        let server = CatalogServer(answers: [[["v", "CREATE VIEW `v` AS SELECT 1"]], []])
        #expect(try await makeCatalog(server).viewDefinition(view: "v", schema: nil) == "CREATE VIEW `v` AS SELECT 1")
        #expect(try await makeCatalog(server, flavor: .starrocks).viewDefinition(view: "v", schema: nil) == nil)
        #expect(await server.sent == ["SHOW CREATE VIEW `shop`.`v`", "SHOW CREATE TABLE `shop`.`v`"])
    }

    @Test("A trigger row becomes a runnable CREATE TRIGGER with its definer and order")
    func triggerList() async throws {
        let server = CatalogServer(answers: [[
            ["audit", "orders", "shop", "BEFORE", "INSERT", "ROW", "SET NEW.at = NOW()", nil, "root@%", "2"],
        ]])

        let triggers = try await makeCatalog(server).allTriggers(schema: nil)

        #expect(await server.sent == [MySQLObjectQueries.triggerList(schema: "shop", table: nil)])
        let trigger = try #require(triggers.first)
        #expect(trigger.name == "audit")
        #expect(trigger.table == "orders")
        #expect(trigger.definition == """
            CREATE DEFINER = `root`@`%` TRIGGER `shop`.`audit` BEFORE INSERT ON `shop`.`orders` FOR EACH ROW
            SET NEW.at = NOW()
            """)
        #expect(trigger.attributes.map(\.label) == ["Definer", "Action Order"])
    }

    @Test("A trigger that already carries its definition is returned without a read")
    func triggerDDLWithDefinition() async throws {
        let server = CatalogServer()
        let trigger = PluginTriggerInfo(
            name: "audit", table: "orders", timing: "BEFORE", event: "INSERT",
            statement: "BEGIN END", definition: "CREATE TRIGGER audit BEFORE INSERT ON orders FOR EACH ROW BEGIN END"
        )
        #expect(try await makeCatalog(server).triggerDDL(trigger).hasPrefix("CREATE TRIGGER audit"))
        #expect(await server.sent.isEmpty)
    }

    @Test("Events are listed with their state, and their DDL is the fourth column of SHOW CREATE EVENT")
    func events() async throws {
        let server = CatalogServer(answers: [
            [["nightly", "RECURRING", "ENABLED", "shop"], ["once", "ONE TIME", "DISABLED", "shop"]],
            [["nightly", "", "", "CREATE EVENT `nightly` ON SCHEDULE EVERY 1 DAY DO SELECT 1"]],
        ])
        let catalog = makeCatalog(server)

        let events = try await catalog.events(schema: nil)
        let ddl = try await catalog.eventDDL(events[0])

        #expect(events.map(\.name) == ["nightly", "once"])
        #expect(events.map(\.isEnabled) == [true, false])
        #expect(ddl.hasPrefix("CREATE EVENT `nightly`"))
        #expect(await server.sent == [
            MySQLObjectQueries.eventList(schema: "shop", exactSchema: false),
            "SHOW CREATE EVENT `shop`.`nightly`",
        ])
    }

    @Test("A creation scope takes the row named exactly, not a case variant the catalog also returned")
    func creationScopeExactName() async throws {
        let server = CatalogServer(answers: [[["CLEANUP", "ANSI_QUOTES"], ["cleanup", "STRICT_TRANS_TABLES"]]])
        let routine = PluginRoutineInfo(name: "cleanup", kind: .procedure, schema: "app")

        let scope = try await makeCatalog(server).routineCreationScope(routine)

        #expect(await server.sent == [MySQLObjectQueries.routineCreationSettings(
            schema: "app", name: "cleanup", kind: "PROCEDURE", exactSchema: false
        )])
        #expect(scope == MySQLExportCatalog.creationScope(sqlMode: "STRICT_TRANS_TABLES", timeZone: nil))
    }

    @Test("Foreign keys are two single-catalog reads merged by table and constraint")
    func catalogForeignKeys() async throws {
        let server = CatalogServer(answers: [
            [
                ["lines", "fk_order", "order_id", "shop", "orders", "id"],
                ["lines", "fk_item", "item_id", nil, "items", "id"],
            ],
            [["lines", "fk_order", "CASCADE", "RESTRICT"]],
        ])

        let keys = try await makeCatalog(server).catalogForeignKeys(database: "shop", table: nil)

        #expect(await server.sent == [
            MySQLObjectQueries.foreignKeyColumns(schema: "shop", table: nil),
            MySQLObjectQueries.referentialActions(schema: "shop", table: nil),
        ])
        let lines = try #require(keys["lines"])
        #expect(lines.map(\.name) == ["fk_order", "fk_item"])
        #expect(lines[0].onDelete == "CASCADE")
        #expect(lines[0].onUpdate == "RESTRICT")
        let omitted = MySQLServerVersion.omittedForeignKeyAction(banner: "8.0.36", flavor: .mysql)
        #expect(lines[1].onDelete == omitted)
    }

    @Test("A database with no foreign key columns skips the actions read")
    func noForeignKeysSkipsActions() async throws {
        let server = CatalogServer()
        let keys = try await makeCatalog(server).catalogForeignKeys(database: "shop", table: "orders")
        #expect(keys.isEmpty)
        #expect(await server.sent == [MySQLObjectQueries.foreignKeyColumns(schema: "shop", table: "orders")])
    }

    @Test("The bulk column read marks keys, generated and auto-increment columns per table")
    func informationSchemaColumns() async throws {
        let server = CatalogServer(answers: [[
            ["orders", "id", "int", nil, "NO", "PRI", nil, "auto_increment", "", nil],
            ["orders", "total", "decimal(10,2)", nil, "YES", "", nil, "", "Order total", nil],
            ["orders", "doubled", "decimal(10,2)", nil, "YES", "", nil, "VIRTUAL GENERATED", "", "(`total` * 2)"],
            ["items", "state", "enum('a','b')", "utf8mb4_bin", "NO", "", "a", "", "", nil],
        ]])

        let columns = try await makeCatalog(server).informationSchemaColumns(schema: nil, table: nil)

        #expect(await server.sent == [
            MySQLObjectQueries.columnCatalog(schema: "shop", table: nil, projectsGenerationExpression: true),
        ])
        let orders = try #require(columns["orders"])
        #expect(orders.map(\.name) == ["id", "total", "doubled"])
        #expect(orders.map(\.isPrimaryKey) == [true, false, false])
        #expect(orders[0].identityKind != nil)
        #expect(orders.map(\.isGenerated) == [false, false, true])
        #expect(orders[2].generationExpression == "(`total` * 2)")
        #expect(orders[1].comment == "Order total")
        #expect(orders[1].dataType == "DECIMAL(10,2)")
        let state = try #require(columns["items"]?.first)
        #expect(state.dataType == "enum('a','b')")
        #expect(state.allowedValues == ["a", "b"])
        #expect(state.charset == "utf8mb4")
    }

    @Test("Opening a verbatim read scope saves the settings, holds the session, then sets them")
    func openVerbatimReadScope() async throws {
        let server = CatalogServer(answers: [[["sql_mode", "STRICT_TRANS_TABLES"], ["time_zone", "SYSTEM"]]])
        let footprint = FootprintBox()
        let hooks = MySQLExportCatalog.SessionHooks(
            runSetup: { await server.answer($0) },
            transactionState: { .idle },
            adjustFootprint: { change in footprint.adjust(change) }
        )

        let scope = try await makeCatalog(server).openSessionScope(for: .verbatimRead, hooks: hooks)

        let capture = try #require(MySQLSessionStatements.captureQuery(names: MySQLSessionScopePlan.verbatimNames))
        let setMode = try #require(MySQLSessionStatements.assignment(name: "sql_mode", value: ""))
        let setZone = try #require(MySQLSessionStatements.assignment(name: "time_zone", value: "+00:00"))
        #expect(await server.sent == [capture, setMode, setZone])
        #expect(scope?.applied.map(\.name) == ["sql_mode", "time_zone"])
        #expect(footprint.heldSessionScopes == 1)
    }

    @Test("Principals read the connection limit where the server has it, and default the host")
    func principals() async throws {
        let server = CatalogServer(answers: [[["app", "%", "0"], ["batch", nil, "5"]]])

        let principals = try await makeCatalog(server).principals()

        #expect(await server.sent == ["SELECT User, Host, max_user_connections FROM mysql.user ORDER BY User, Host"])
        #expect(principals.map(\.ref.host) == ["%", "%"])
        #expect(principals.map(\.connectionLimit) == [nil, 5])
    }

    @Test("Grants are read for the quoted account and written back as GRANT statements")
    func grantsRoundTrip() async throws {
        let server = CatalogServer(answers: [[["GRANT SELECT, INSERT ON `shop`.* TO `app`@`%`"]]])
        let catalog = makeCatalog(server)
        let principal = PluginPrincipalRef(name: "app", host: "%")
        let privileges = PluginPrivilegeCatalog(
            serverPrivileges: [], databasePrivileges: [], schemaPrivileges: [],
            tablePrivileges: [], columnPrivileges: [], supportsDynamicPrivileges: false
        )

        let grants = try await catalog.grants(for: principal, privileges: privileges)

        #expect(await server.sent == ["SHOW GRANTS FOR `app`@`%`"])
        #expect(Set(grants.map(\.privilege)) == ["SELECT", "INSERT"])
        #expect(grants.allSatisfy { $0.scope == .database("shop") })
        let statements = catalog.grantStatements(
            for: principal,
            grants: [PluginGrantInfo(privilege: "SELECT", scope: .table(database: "shop", schema: nil, table: "orders"))]
        )
        #expect(statements == ["GRANT SELECT ON `shop`.`orders` TO `app`@`%`"])
    }

    @Test("A database-level grant target escapes LIKE wildcards; a table-level one does not")
    func grantTargets() {
        let quote: (String) -> String = { mysqlQuoteIdentifier($0) }
        #expect(MySQLExportCatalog.grantTarget(for: .database("my_db"), quote: quote) == "`my\\_db`.*")
        #expect(MySQLExportCatalog.grantTarget(
            for: .table(database: "my_db", schema: nil, table: "t"), quote: quote
        ) == "`my_db`.`t`")
        #expect(MySQLExportCatalog.grantTarget(for: .server, quote: quote) == "*.*")
    }

    @Test("A routine drop names its kind and never DROP ROUTINE")
    func dropRoutineStatement() {
        let catalog = makeCatalog(CatalogServer())
        #expect(catalog.dropRoutineStatement(name: "total", schema: nil, isFunction: true)
            == "DROP FUNCTION IF EXISTS `shop`.`total`")
        #expect(catalog.dropRoutineStatement(name: "cleanup", schema: "app", isFunction: false)
            == "DROP PROCEDURE IF EXISTS `app`.`cleanup`")
        #expect(makeCatalog(CatalogServer(), flavor: .databend)
            .dropRoutineStatement(name: "f", schema: nil, isFunction: true) == nil)
    }

    @Test("A trigger drop is qualified by the effective database")
    func dropTriggerStatement() {
        let catalog = makeCatalog(CatalogServer())
        #expect(catalog.dropTriggerStatement(name: "audit", schema: nil) == "DROP TRIGGER `shop`.`audit`")
    }

    @Test("The row count read is the catalog's TABLE_ROWS")
    func approximateRowCount() async throws {
        let server = CatalogServer(answers: [[["42"]], [[nil]]])
        let catalog = makeCatalog(server)
        #expect(try await catalog.approximateRowCount(table: "orders", schema: nil) == 42)
        #expect(try await catalog.approximateRowCount(table: "orders", schema: "app") == nil)
        #expect(await server.sent == [
            MySQLObjectQueries.approximateRowCount(schema: "shop", table: "orders"),
            MySQLObjectQueries.approximateRowCount(schema: "app", table: "orders"),
        ])
    }

    @Test("A SQL file import turns foreign key checks off and on where the flavor has them")
    func foreignKeyCheckStatements() {
        #expect(MySQLServerFlavor.mysql.foreignKeyCheckStatements(enabled: false) == ["SET FOREIGN_KEY_CHECKS=0"])
        #expect(MySQLServerFlavor.mariadb.foreignKeyCheckStatements(enabled: true) == ["SET FOREIGN_KEY_CHECKS=1"])
        #expect(MySQLServerFlavor.databend.foreignKeyCheckStatements(enabled: false) == nil)
        #expect(MySQLServerFlavor.starrocks.foreignKeyCheckStatements(enabled: true) == nil)
    }

    @Test("The plugin driver forwards drop statements and foreign key checks to the shared catalog")
    func driverForwards() {
        let driver = MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "shop", additionalFields: [:]
        ))
        #expect(driver.generateDropRoutineSQL(name: "p", signature: "(IN a int)", schema: nil, isFunction: false)
            == "DROP PROCEDURE IF EXISTS `shop`.`p`")
        #expect(driver.generateDropTriggerSQL(name: "t", table: "orders", schema: "app") == "DROP TRIGGER `app`.`t`")
        #expect(driver.foreignKeyDisableStatements() == ["SET FOREIGN_KEY_CHECKS=0"])
        #expect(driver.foreignKeyEnableStatements() == ["SET FOREIGN_KEY_CHECKS=1"])
        #expect(driver.tableDDLIncludesForeignKeys)
    }
}

// MySQL and MariaDB keep two tables whose names differ only in Unicode form apart, which a String key merges.
extension MySQLExportCatalogTests {
    private static let composed = "caf\u{E9}"
    private static let decomposed = "cafe\u{301}"

    @Test("The export's column read throws on two tables named alike in different Unicode forms")
    func exportColumnReadThrowsOnTwins() async throws {
        let server = CatalogServer(answers: [[
            [.text(Self.composed), "id", "int", nil, "NO", "PRI", nil, "", "", nil],
            [.text(Self.decomposed), "id", "int", nil, "NO", "PRI", nil, "", "", nil],
        ]])

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await makeCatalog(server).informationSchemaColumns(schema: nil, table: nil, keepsSpellingsApart: true)
        }
        #expect(await server.sent == [
            MySQLObjectQueries.columnCatalog(schema: "shop", table: nil, projectsGenerationExpression: true),
        ])
    }

    @Test("The export's key read throws on two tables named alike in different Unicode forms")
    func exportKeyReadThrowsOnTwins() async throws {
        let server = CatalogServer(answers: [
            [
                [.text(Self.composed), "fk_a", "a", "shop", "p", "id"],
                [.text(Self.decomposed), "fk_b", "b", "shop", "p", "id"],
            ],
            [],
        ])

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await makeCatalog(server).catalogForeignKeys(database: "shop", table: nil, keepsSpellingsApart: true)
        }
    }

    @Test("Without twins the export reads send the shared reads' statements and answer alike")
    func exportReadsMatchTheSharedReads() async throws {
        let columnRows: [[PluginCellValue]] = [
            ["orders", "id", "int", nil, "NO", "PRI", nil, "", "", nil],
            ["lines", "order_id", "int", nil, "NO", "", nil, "", "", nil],
        ]
        let keyRows: [[PluginCellValue]] = [["lines", "fk_order", "order_id", "shop", "orders", "id"]]
        let actionRows: [[PluginCellValue]] = [["lines", "fk_order", "CASCADE", "RESTRICT"]]
        let shared = CatalogServer(answers: [columnRows, keyRows, actionRows])
        let exported = CatalogServer(answers: [columnRows, keyRows, actionRows])

        let sharedColumns = try await makeCatalog(shared).informationSchemaColumns(schema: nil, table: nil)
        let sharedKeys = try await makeCatalog(shared).catalogForeignKeys(database: "shop", table: nil)
        let exportColumns = try await makeCatalog(exported)
            .informationSchemaColumns(schema: nil, table: nil, keepsSpellingsApart: true)
        let exportKeys = try await makeCatalog(exported)
            .catalogForeignKeys(database: "shop", table: nil, keepsSpellingsApart: true)

        #expect(await exported.sent == shared.sent)
        #expect(await exported.sent.count == 3)
        #expect(exportColumns.mapValues { columns in columns.map { $0.name } }
            == sharedColumns.mapValues { columns in columns.map { $0.name } })
        #expect(exportKeys["lines"]?.map { $0.name } == sharedKeys["lines"]?.map { $0.name })
    }
}
