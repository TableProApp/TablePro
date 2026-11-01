import Foundation
import TableProNeo4jCore
import TableProPluginKit

// Run by check-neo4j.sh against a live server. Exits 1 on the first expectation that fails.

let environment = ProcessInfo.processInfo.environment
var ssl = SSLConfiguration()
ssl.mode = SSLMode(rawValue: environment["TP_NEO4J_SSL_MODE"] ?? "") ?? .disabled
ssl.caCertificatePath = environment["TP_NEO4J_CA"] ?? ""
let driver = Neo4jPluginDriver(config: DriverConnectionConfig(
    host: environment["TP_NEO4J_HOST"] ?? "127.0.0.1",
    port: Int(environment["TP_NEO4J_PORT"] ?? "") ?? 7_687,
    username: environment["TP_NEO4J_USER"] ?? "neo4j",
    password: environment["TP_NEO4J_PASSWORD"] ?? "",
    database: "",
    ssl: ssl
))
let label = "TableProProbe\(Int.random(in: 100_000 ... 999_999))"
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func text(_ result: PluginQueryResult) -> [[String?]] {
    result.rows.map { $0.map(\.asText) }
}

func run() async throws {
    try await driver.connect()
    print("server: \(driver.serverVersion ?? "unknown"), database: \(driver.currentDatabase)")

    _ = try await driver.execute(query: """
    CREATE (a:\(label) {name: 'Ann', age: 30, born: date('1994-05-01')}),
           (b:\(label) {name: 'Bo', email: 'bo@example.com'}),
           (a)-[:\(label)_KNOWS {since: 2020}]->(b)
    """)

    let databases = try await driver.fetchDatabases()
    expect(databases.contains(driver.currentDatabase), "the current database is listed: \(databases)")

    let tables = try await driver.fetchTablesInAllSchemas() ?? []
    expect(tables.contains { $0.name == label && $0.schema == "Labels" }, "the label is listed under Labels")
    expect(tables.contains { $0.name == "\(label)_KNOWS" && $0.schema == "Relationship Types" },
           "the relationship type is listed under Relationship Types")

    let columns = try await driver.fetchColumns(table: label, schema: "Labels").map(\.name)
    expect(columns == ["<id>", "<labels>", "age", "born", "email", "name"], "columns: \(columns)")
    let count = try await driver.fetchApproximateRowCount(table: label, schema: "Labels")
    expect(count == 2, "row count: \(String(describing: count))")

    let nameIndex = try require(columns.firstIndex(of: "name"))
    let browse = try require(driver.buildBrowseQuery(
        table: label, schema: "Labels", sortColumns: [(nameIndex, true)], columns: columns, limit: 200, offset: 0
    ))
    let page = try await driver.execute(query: browse)
    expect(page.columns == columns, "browse columns: \(page.columns)")
    expect(text(page).map { $0[nameIndex] } == ["Ann", "Bo"], "browse sorts by name")
    expect(text(page).first?[columns.firstIndex(of: "born") ?? 0] == "1994-05-01", "a date reads as Cypher writes it")

    let relationships = try await driver.execute(query: try require(driver.buildBrowseQuery(
        table: "\(label)_KNOWS", schema: "Relationship Types", sortColumns: [], columns: [], limit: 200, offset: 0
    )))
    expect(relationships.columns == ["<id>", "<start>", "<end>", "since"], "relationship columns: \(relationships.columns)")

    let ageFilter = [PluginQueryFilter(column: "age", op: "CONTAINS", value: "3", isCaseSensitive: false)]
    let filtered = try await driver.execute(query: try require(driver.buildFilteredQuery(
        table: label, schema: "Labels", queryFilters: ageFilter, logicMode: "and",
        sortColumns: [], columns: columns, limit: 200, offset: 0, columnKinds: [:]
    )))
    expect(text(filtered).map { $0[nameIndex] } == ["Ann"], "a text filter on an integer property matches as text")
    let filteredCount = try await driver.fetchFilteredRowCount(table: label, queryFilters: ageFilter, logicMode: "and")
    expect(filteredCount == 1, "a filtered count: \(String(describing: filteredCount))")

    let escapeColumn = #"x\u0060 IS NULL WITH n DETACH DELETE n WITH n WHERE n.\u0060x"#
    do {
        _ = try await driver.fetchFilteredRowCount(
            table: label, queryFilters: [PluginQueryFilter(column: escapeColumn, op: "IS NULL", value: "")], logicMode: "and"
        )
        expect(false, "a column holding a unicode escape is refused")
    } catch {
        expect(true, "a column holding a unicode escape is refused")
    }
    do {
        _ = try await driver.execute(query: "MATCH (n:\(label)) WHERE n.\(Neo4jCypher.quote(escapeColumn)) IS NULL RETURN count(n)")
        expect(false, "a quoted unicode escape fails on the server")
    } catch {
        expect(true, "a quoted unicode escape fails on the server")
    }
    let afterEscape = try await driver.fetchApproximateRowCount(table: label, schema: "Labels")
    expect(afterEscape == 2, "no node was deleted through a quoted name: \(String(describing: afterEscape))")

    _ = try await driver.execute(query: "CREATE INDEX \(label)_name IF NOT EXISTS FOR (n:\(label)) ON (n.name)")
    let indexes = try await driver.fetchIndexes(table: label, schema: "Labels").map(\.name)
    expect(indexes == ["\(label)_name"], "the label's index is listed: \(indexes)")
    let relationshipIndexes = try await driver.fetchIndexes(table: label, schema: "Relationship Types")
    expect(relationshipIndexes.isEmpty, "a relationship type does not borrow a label's index")
    _ = try await driver.execute(query: "DROP INDEX \(label)_name IF EXISTS")

    let capped = try await driver.executeUserQuery(query: "UNWIND range(1, 50) AS x RETURN x", rowCap: 10, parameters: nil)
    expect(capped.rows.count == 10 && capped.isTruncated, "a row cap truncates on the server")
    let afterCap = try await driver.execute(query: "RETURN 3 AS ok")
    expect(text(afterCap) == [["3"]], "the next statement runs after a capped one")

    let cappedWrite = try await driver.executeUserQuery(
        query: "UNWIND range(1, 12) AS x CREATE (n:\(label) {seq: x}) RETURN n", rowCap: 10, parameters: nil
    )
    expect(cappedWrite.rows.count == 10 && cappedWrite.isTruncated, "a capped write returns the capped rows")
    expect(cappedWrite.rowsAffected == 12, "a capped write counts every node it created: \(cappedWrite.rowsAffected)")
    _ = try await driver.execute(query: "MATCH (n:\(label)) WHERE n.seq IS NOT NULL DELETE n")

    let setOnly = try await driver.execute(query: "MATCH (n:\(label) {name: 'Ann'}) SET n.a = 1, n.b = 2")
    expect(setOnly.rowsAffected == 0 && setOnly.statusMessage == "2 property value(s) set",
           "a property update reports its counter: \(setOnly.rowsAffected), \(setOnly.statusMessage ?? "nil")")

    let duration = try await driver.execute(query: "RETURN duration({seconds: 10000000000}) AS d")
    expect(text(duration) == [["PT2777777H46M40S"]], "a long duration formats: \(text(duration))")

    let path = try await driver.execute(
        query: "MATCH p = (:\(label) {name: 'Bo'})<-[:\(label)_KNOWS]-(:\(label) {name: 'Ann'}) RETURN p"
    )
    let pathObject = try require(text(path).first?.first.flatMap { $0 }.flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    })
    let pathNodes = (pathObject["nodes"] as? [[String: Any]] ?? []).compactMap { $0["elementId"] as? String }
    let pathStep = (pathObject["relationships"] as? [[String: Any]])?.first
    expect(pathNodes.count == 2 && pathStep?["startElementId"] as? String == pathNodes.last
               && pathStep?["endElementId"] as? String == pathNodes.first,
           "a path walked against its relationship keeps the relationship's direction")

    try await checkReadModeFiltersExportAndCancel(columns: columns, nameIndex: nameIndex)

    try driver.cancelQuery()
    let afterIdleCancel = try await driver.execute(query: "RETURN 4 AS ok")
    expect(text(afterIdleCancel) == [["4"]], "a cancel with nothing running leaves the next statement alone")

    do {
        _ = try await driver.execute(query: "MATCH (n RETURN n")
        expect(false, "a syntax error throws")
    } catch {
        expect(true, "a syntax error throws: \(error.localizedDescription.prefix(60))")
    }
    let afterError = try await driver.execute(query: "RETURN 1 AS ok")
    expect(text(afterError) == [["1"]], "the connection recovers after an error")

    let slow = Task { try await driver.execute(query: "UNWIND range(1, 1000000000) AS x WITH x WHERE x < 0 RETURN count(x)") }
    try await Task.sleep(nanoseconds: 500_000_000)
    try driver.cancelQuery()
    do {
        _ = try await slow.value
        expect(false, "cancel stops a running query")
    } catch {
        expect(true, "cancel stops a running query")
    }
    let afterCancel = try await driver.execute(query: "RETURN 2 AS ok")
    expect(text(afterCancel) == [["2"]], "the connection recovers after a cancel")
}

func checkReadModeFiltersExportAndCancel(columns: [String], nameIndex: Int) async throws {
    var readContext = PluginStatementContext()
    readContext.readOnly = true
    do {
        _ = try await driver.execute(query: "CREATE (n:\(label) {probe: 'read mode'})", context: readContext)
        expect(false, "a statement marked read-only cannot write")
    } catch {
        expect(true, "a statement marked read-only cannot write: \(error.localizedDescription.prefix(70))")
    }
    let rawWrite = [PluginQueryFilter(column: "__RAW__", op: "", value: "true WITH n SET n.raw = 1 WITH n WHERE true")]
    do {
        _ = try await driver.execute(query: try require(driver.buildFilteredQuery(
            table: label, schema: "Labels", queryFilters: rawWrite, logicMode: "and",
            sortColumns: [], columns: columns, limit: 200, offset: 0, columnKinds: [:]
        )))
        expect(false, "a raw filter cannot write through a grid page")
    } catch {
        expect(true, "a raw filter cannot write through a grid page")
    }
    let rawCount = try await driver.execute(query: "MATCH (n:\(label)) WHERE n.raw IS NOT NULL RETURN count(n)")
    expect(text(rawCount) == [["0"]], "no property was set by the raw filter")

    func filteredNames(_ filters: [PluginQueryFilter]) async throws -> [String?] {
        let page = try await driver.execute(query: try require(driver.buildFilteredQuery(
            table: label, schema: "Labels", queryFilters: filters, logicMode: "and",
            sortColumns: [(nameIndex, true)], columns: columns, limit: 200, offset: 0, columnKinds: [:]
        )))
        return text(page).map { $0[nameIndex] }
    }
    let between = try await filteredNames([PluginQueryFilter(column: "age", op: "BETWEEN", value: "20,40", secondValue: "40", elementScope: nil)])
    expect(between == ["Ann"], "BETWEEN uses both bounds: \(between)")
    let byLabel = try await filteredNames([PluginQueryFilter(column: "<labels>", op: "=", value: label)])
    expect(byLabel == ["Ann", "Bo"], "<labels> = matches a node carrying the label: \(byLabel)")
    let notLabel = try await filteredNames([PluginQueryFilter(column: "<labels>", op: "!=", value: label)])
    expect(notLabel.isEmpty, "<labels> != excludes it: \(notLabel)")
    let regex = try await filteredNames([PluginQueryFilter(column: "age", op: "REGEX", value: "3.*")])
    expect(regex == ["Ann"], "REGEX on an integer property matches it as text: \(regex)")

    _ = try await driver.execute(query: "UNWIND range(1, 2500) AS x CREATE (:\(label)_Bulk {seq: x})")
    let export = try require(driver.defaultExportQuery(table: "\(label)_Bulk", schema: "Labels"))
    var exportColumns: [String] = []
    var exportRows = 0
    var exportBatches = 0
    for try await element in driver.streamRows(query: export) {
        switch element {
        case .header(let header): exportColumns = header.columns
        case .rows(let rows):
            exportRows += rows.count
            exportBatches += 1
        }
    }
    expect(exportColumns == ["<id>", "<labels>", "seq"], "an export spreads entities: \(exportColumns)")
    expect(exportRows == 2_500 && exportBatches == 3, "an export pulls in batches: \(exportRows) rows in \(exportBatches)")
    let slowFilter = [PluginQueryFilter(
        column: "__RAW__", op: "", value: "size([x IN range(1, 200000) WHERE x < 0]) = 0"
    )]
    let countStarted = Date()
    let slowCount = Task {
        try await driver.fetchFilteredRowCount(table: "\(label)_Bulk", queryFilters: slowFilter, logicMode: "and")
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    let queued = Task { try await driver.execute(query: "RETURN 5 AS queued") }
    try await Task.sleep(nanoseconds: 300_000_000)
    try driver.cancelQuery()
    let countAfterCancel = try? await slowCount.value
    print("info the slow count took \(Int(Date().timeIntervalSince(countStarted) * 1_000)) ms")
    expect(countAfterCancel == 2_500, "a cancel leaves metadata work holding the connection alone: \(String(describing: countAfterCancel))")
    do {
        _ = try await queued.value
        expect(false, "a cancel stops the user statement waiting for its turn")
    } catch {
        expect(true, "a cancel stops the user statement waiting for its turn")
    }
    _ = try await driver.execute(query: "MATCH (n:\(label)_Bulk) DELETE n")

    let decoded = try await driver.execute(query: "RETURN 1 AS \\u0061bc")
    print("info the server decodes unicode escapes outside strings: \(decoded.columns == ["abc"])")

    var preferred = SSLConfiguration()
    preferred.mode = .preferred
    let fallback = Neo4jPluginDriver(config: DriverConnectionConfig(
        host: environment["TP_NEO4J_HOST"] ?? "127.0.0.1",
        port: Int(environment["TP_NEO4J_PORT"] ?? "") ?? 7_687,
        username: environment["TP_NEO4J_USER"] ?? "neo4j",
        password: environment["TP_NEO4J_PASSWORD"] ?? "",
        database: "",
        ssl: preferred
    ))
    do {
        try await fallback.connect()
        let ping = try await fallback.execute(query: "RETURN 6 AS ok")
        expect(text(ping) == [["6"]], "SSL Preferred connects to a server without TLS")
    } catch {
        expect(ssl.mode != .disabled, "SSL Preferred connects to a server without TLS: \(error.localizedDescription)")
    }
    fallback.disconnect()
}

struct RequireError: Error {}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw RequireError() }
    return value
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        try await run()
        _ = try? await driver.execute(query: "MATCH (n:\(label)) DETACH DELETE n")
    } catch {
        print("FAIL \(error.localizedDescription)")
        failures += 1
    }
    driver.disconnect()
    done.signal()
}
done.wait()
exit(failures == 0 ? 0 : 1)
