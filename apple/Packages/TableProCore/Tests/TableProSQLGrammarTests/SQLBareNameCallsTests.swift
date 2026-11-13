import Foundation
import TableProSQLGrammar
import Testing

// The cases are the ones measured on Oracle 23ai and DM8: a function PURGE and WIPE, a package PK with F, a table
// ORDERS(ID, PURGE). Each answer is whether the engine ran a function.
struct SQLBareNameCallsTests {
    private static let orders = SQLTableName(owner: nil, name: "ORDERS")
    private static let dual = SQLTableName(owner: nil, name: "DUAL")
    private static let ownedOrders = SQLTableName(owner: "PROBE", name: "ORDERS")
    private static let catalog = SQLCallableCatalog(functions: ["PURGE", "WIPE"], roots: ["PK", "PROBE"])
    private static let columns: [SQLTableName: Set<String>] = [
        orders: ["ID", "PURGE"], dual: ["DUMMY"], ownedOrders: ["ID", "PURGE"],
    ]

    private static func reading(_ sql: String, _ engine: String = "Oracle") -> SQLBareNameReading {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLBareNameCalls.read(sql, databaseTypeId: engine, readings: readings)
    }

    private static func calls(_ sql: String, _ engine: String = "Oracle", catalog: SQLCallableCatalog = catalog) -> Bool {
        reading(sql, engine).callsFunction(catalog, columns: columns)
    }

    @Test("A name no table in scope has as a column calls the function", arguments: [
        "SELECT purge FROM dual",
        "SELECT wipe FROM orders",
        "SELECT * FROM orders, (SELECT purge FROM dual)",
        "SELECT * FROM orders o JOIN (SELECT purge p FROM dual) d ON 1 = 1",
        "SELECT 1 AS wipe FROM dual WHERE wipe = 7",
        "SELECT 1 wipe FROM dual GROUP BY wipe",
        "SELECT COUNT(*) FROM orders WHERE wipe = 7",
        "SELECT \"WIPE\" FROM dual",
        "SELECT * FROM orders WHERE id = 1 ORDER BY wipe",
        "SELECT id, purge FROM orders UNION ALL SELECT 1, purge FROM dual",
        "SELECT * FROM orders WHERE purge BETWEEN wipe AND 1000",
        "SELECT CASE WHEN wipe = 7 THEN 1 END FROM dual",
        "SELECT t.* FROM (SELECT id x FROM orders) t WHERE wipe = 7",
        "SELECT wipe FROM orders PIVOT (SUM(purge) FOR id IN (1 AS a))",
        "SELECT id FROM orders o WHERE EXISTS (SELECT 1 FROM orders i WHERE i.id = o.id AND wipe = 7)",
        "SELECT id FROM orders\nSELECT purge FROM dual",
        "SELECT 1 FROM dual\nWITH c AS (SELECT purge FROM dual) SELECT * FROM c",
        "EXPLAIN PLAN FOR SELECT 1 FROM dual\nSELECT purge FROM dual",
        "SELECT wipe",
    ])
    func bareCalls(sql: String) {
        #expect(Self.calls(sql))
        #expect(Self.calls(sql, "Dameng"))
    }

    @Test("A column, an alias ORDER BY sees and a name the query defines call nothing", arguments: [
        "SELECT purge FROM orders",
        "SELECT o.purge FROM orders o",
        "SELECT id FROM orders WHERE EXISTS (SELECT 1 FROM dual WHERE purge = 100)",
        "SELECT * FROM orders o, LATERAL (SELECT purge FROM dual)",
        "SELECT (SELECT purge FROM dual) FROM orders",
        "SELECT 1 AS wipe FROM dual ORDER BY wipe",
        "SELECT purge p FROM orders ORDER BY p",
        "WITH c AS (SELECT 1 wipe FROM dual) SELECT wipe FROM c",
        "WITH c (wipe) AS (SELECT 1 FROM dual) SELECT wipe FROM c",
        "SELECT purge FROM (SELECT * FROM orders)",
        "SELECT * FROM (SELECT purge FROM orders) WHERE purge > 0",
        "SELECT probe.orders.purge FROM probe.orders",
        "SELECT \"wipe\" FROM dual",
        "SELECT id wipe FROM orders",
        "SELECT id FROM orders WHERE id = :wipe",
        "SELECT seq.NEXTVAL FROM dual",
        "SELECT LISTAGG(id, ',') WITHIN GROUP (ORDER BY id) FROM orders",
        "SELECT * FROM wipe",
        "SELECT CAST(id AS wipe) FROM orders",
        "SELECT id FROM orders o WHERE o.id IN (SELECT id FROM orders o2 WHERE o2.purge = o.purge)",
        "SELECT 1 wipe FROM dual UNION SELECT 2 FROM dual ORDER BY wipe",
        "EXPLAIN PLAN FOR SELECT purge FROM dual",
    ])
    func noCalls(sql: String) {
        #expect(!Self.calls(sql))
    }

    @Test("A dotted name no table in scope starts calls without the catalog", arguments: [
        "SELECT pk.f FROM dual",
        "SELECT probe.wipe FROM dual",
        "SELECT probe.pk.f FROM dual",
        "SELECT * FROM orders WHERE id IN (SELECT pk.f FROM dual)",
        "SELECT wipe@remote FROM dual",
        "WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 1; END; SELECT f FROM dual",
    ])
    func dottedCalls(sql: String) {
        let reading = Self.reading(sql)
        #expect(reading.callsOutright)
        #expect(reading.callsFunction(SQLCallableCatalog(functions: [], roots: []), columns: [:]))
    }

    @Test("Dameng calls package PK through an alias whose table has no such column")
    func aliasFallsToPackage() {
        #expect(Self.calls("SELECT pk.f FROM orders pk", "Dameng"))
        #expect(!Self.calls("SELECT pk.id FROM orders pk", "Dameng"))
        #expect(!Self.calls("SELECT pk.f FROM orders pk", "Dameng", catalog: SQLCallableCatalog(functions: [], roots: [])))
    }

    // Measured on Oracle 23ai: functions RUNNING, FINAL and WIPE did not run for these.
    @Test("MATCH_RECOGNIZE's own words, a measure's alias, a pattern variable and RUNNING or FINAL before a call are not calls")
    func rowPatternClauseNames() {
        let catalog = SQLCallableCatalog(
            functions: [
                "WIPE", "RUNNING", "FINAL", "MEASURES", "ONE", "ROW", "ROWS", "PER", "MATCH", "AFTER", "SKIP", "PAST",
                "LAST", "NEXT", "FIRST", "SUBSET", "DEFINE", "X", "Y", "U", "EMPTY", "MATCHES", "SHOW",
            ],
            roots: []
        )
        for sql in [
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES x.id AS wipe ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1)",
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES FINAL LAST(x.purge) AS l, RUNNING COUNT(*) AS c "
                + "ALL ROWS PER MATCH SHOW EMPTY MATCHES AFTER MATCH SKIP PAST LAST ROW PATTERN (x y*) SUBSET u = (x, y) "
                + "DEFINE x AS RUNNING COUNT(*) < 9, y AS u.purge > PREV(y.purge))",
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES x.id wipe AFTER MATCH SKIP TO NEXT ROW PATTERN (x) "
                + "DEFINE x AS CAST(x.purge AS NUMBER) > 0)",
        ] {
            #expect(!Self.calls(sql, catalog: catalog), "\(sql)")
        }
        #expect(Self.calls(
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS final > 1)", catalog: catalog
        ))
    }

    @Test("A VALUES row, a MATCH_RECOGNIZE condition and a PARTITION FOR value are read")
    func rowValuesAndConditions() {
        #expect(Self.calls("SELECT * FROM (VALUES (wipe)) t (a)"))
        #expect(Self.calls("SELECT * FROM orders, (VALUES (purge)) v (a)"))
        #expect(!Self.calls("SELECT a FROM (VALUES (1)) t (a)"))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (PATTERN (x) DEFINE x AS wipe = 1)"))
        #expect(!Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (PATTERN (x) DEFINE x AS purge = 100)"))
        #expect(!Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (PATTERN (up+) DEFINE up AS up.purge > 1)"))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (PATTERN (up+) DEFINE up AS other.purge > 1)"))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (MEASURES wipe AS w PATTERN (x) DEFINE x AS 1 = 1)"))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (MEASURES x.id w, wipe m PATTERN (x) DEFINE x AS 1 = 1)"))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (PARTITION BY wipe PATTERN (x) DEFINE x AS 1 = 1)"))
        // Measured on Oracle 23ai: a section word as an alias or a column opens no section, and WIPE runs.
        #expect(Self.calls(
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES x.id AS subset, wipe AS w PATTERN (x) DEFINE x AS 1 = 1)"
        ))
        #expect(Self.calls(
            "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES x.id AS define, wipe AS w PATTERN (x) DEFINE x AS 1 = 1)"
        ))
        #expect(Self.calls(
            "SELECT * FROM (SELECT id, 1 AS subset FROM orders) MATCH_RECOGNIZE (ORDER BY id MEASURES x.subset + wipe AS m "
                + "PATTERN (x) DEFINE x AS 1 = 1)"
        ))
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (MEASURES subset + wipe AS m PATTERN (x) DEFINE x AS 1 = 1)"))
        // Out of Oracle's order, so the clause is read whole, a name after AS included.
        #expect(Self.calls("SELECT * FROM orders MATCH_RECOGNIZE (DEFINE x AS wipe = 1 PATTERN (x))"))
        #expect(Self.calls("SELECT * FROM orders, dual PIVOT (MAX(purge) FOR dummy IN ('X' AS x))"))
        #expect(!Self.calls("SELECT * FROM orders, dual PIVOT (MAX(dummy) FOR dummy IN ('X' AS x)) WHERE purge = 1"))
        #expect(Self.calls("SELECT * FROM orders PARTITION FOR (wipe)"))
    }

    @Test("Dameng matches a function in any case; Oracle only as stored")
    func damengFoldsFunctionCase() {
        let lower = SQLCallableCatalog(functions: ["wipe"], roots: [])
        #expect(Self.calls("SELECT wipe FROM dual", "Dameng", catalog: lower))
        #expect(!Self.calls("SELECT wipe FROM dual", "Oracle", catalog: lower))
    }

    @Test("A name holding a backslash is never written into the columns query")
    func backslashNamesAreNotWritten() {
        #expect(SQLCallableCatalog.columnsQuery(for: [SQLTableName(owner: nil, name: "A\\B")]) == nil)
    }

    @Test("Dameng's TOP count and LIMIT do not hide a name")
    func damengTopAndLimit() {
        #expect(Self.calls("SELECT TOP 5 wipe FROM dual", "Dameng"))
        #expect(Self.calls("SELECT TOP (5) PERCENT wipe FROM dual", "Dameng"))
        #expect(!Self.calls("SELECT orders.purge FROM orders LIMIT 10", "Dameng"))
    }

    @Test("Only a name the catalog holds asks for columns")
    func columnsOnlyOnAHit() {
        let reading = Self.reading("SELECT purge FROM orders")
        #expect(!reading.namesNothing)
        #expect(reading.tablesToResolve(Self.catalog) == [Self.orders])
        #expect(reading.tablesToResolve(SQLCallableCatalog(functions: ["OTHER"], roots: [])).isEmpty)
        #expect(Self.reading("SELECT 1 FROM dual").namesNothing)
        #expect(Self.reading("UPDATE orders SET purge = wipe").namesNothing)
    }

    @Test("A table whose columns nobody read counts a matching name as a call")
    func unknownColumnsCall() {
        #expect(Self.reading("SELECT purge FROM orders").callsFunction(Self.catalog, columns: [:]))
    }

    @Test("Catalog rows read into functions and roots")
    func catalogRows() {
        let catalog = SQLCallableCatalog(rows: [["F", "PURGE"], ["R", "PK"], ["F", nil], ["X", "Y"], ["F"]])
        #expect(catalog == SQLCallableCatalog(functions: ["PURGE"], roots: ["PK"]))
    }

    @Test("The first rank that resolves a table wins, and a remote one has no columns")
    func columnRows() {
        let tables = [Self.orders, Self.dual, SQLTableName(owner: nil, name: "LINKED")]
        let rows: [[String?]] = [
            ["0", "3", nil, "OTHER"],
            ["0", "1", nil, "ID"],
            ["0", "1", nil, "PURGE"],
            ["1", "3", nil, "DUMMY"],
            ["2", "2", "REMOTE", nil],
        ]
        let columns = SQLCallableCatalog.columns(fromRows: rows, tables: tables)
        #expect(columns == [Self.orders: ["ID", "PURGE"], Self.dual: ["DUMMY"]])
    }

    @Test("The columns query writes each name as a literal and asks public synonyms only for an unowned name")
    func columnsQuery() throws {
        let query = try #require(SQLCallableCatalog.columnsQuery(for: [
            SQLTableName(owner: nil, name: "O'NEIL"), SQLTableName(owner: "APP", name: "T"),
        ]))
        #expect(query.contains("'O''NEIL'"))
        #expect(query.contains("o.OWNER = 'APP'"))
        #expect(query.components(separatedBy: "s.OWNER = 'PUBLIC'").count == 2)
        #expect(SQLCallableCatalog.columnsQuery(for: [SQLTableName(owner: nil, name: "A\u{0}B")]) == nil)
        #expect(SQLCallableCatalog.columnsQuery(for: []) == nil)
    }
}
