import Foundation
import TableProPluginKit
import Testing

enum DynamoDBTestLocal {
    static let host = "127.0.0.1"
    static let port = 18_000

    /// A socket probe rather than an environment variable: `xcodebuild` does not pass the shell's
    /// environment to the test host, so a variable would read as unset on every run.
    static let isReachable: Bool = {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }()

    static func connectedDriver() async throws -> DynamoDBPluginDriver {
        let config = DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: [
                "awsAuthMethod": "local",
                "awsEndpointUrl": "http://\(host):\(port)",
                "awsRegion": "us-east-1"
            ]
        )
        let driver = DynamoDBPluginDriver(config: config, catalog: DynamoDBCatalog())
        try await driver.connect()
        return driver
    }

    static func uniqueTableName(_ prefix: String) -> String {
        "tp_it_\(prefix)_\(UUID().uuidString.prefix(8))"
    }
}

/// Orders across three customers, keyed by customer and order number, with a global index on
/// status and total. Order numbers divisible by four are FAILED.
private struct OrdersFixture {
    static let columns = ["customer", "orderId", "status", "total", "zip", "doc", "tags", "bin", "big"]
    static let keys = ["customer", "orderId"]

    let driver: DynamoDBPluginDriver
    let table: String

    static func make() async throws -> OrdersFixture {
        let driver = try await DynamoDBTestLocal.connectedDriver()
        let table = DynamoDBTestLocal.uniqueTableName("orders")
        let form = PluginCreateTableRequest(
            tableName: table,
            values: [
                "partitionKeyName": "customer", "partitionKeyType": "S",
                "sortKeyName": "orderId", "sortKeyType": "N",
                "billingMode": "PAY_PER_REQUEST", "tableClass": "STANDARD", "deletionProtection": "false"
            ],
            repeatedValues: ["globalIndexes": [[
                "indexName": "byStatus", "partitionKeyName": "status", "partitionKeyType": "S",
                "sortKeyName": "total", "sortKeyType": "N", "projection": "ALL"
            ]]]
        )
        for statement in try driver.createTableStatements(for: form, schema: nil) {
            _ = try await driver.execute(query: statement)
        }
        let fixture = OrdersFixture(driver: driver, table: table)
        try await fixture.seed()
        return fixture
    }

    private func seed() async throws {
        for customer in ["c1", "c2", "c3"] {
            for order in 0..<40 {
                let row: [PluginCellValue] = [
                    .text(customer), .text(String(order)), .text(order % 4 == 0 ? "FAILED" : "PAID"),
                    .text(String(order * 10)), .text("0213\(order % 10)"), .text(#"{"a":{"b":[1,2]}}"#),
                    .text(#"["x","y"]"#), .bytes(Data([0xDE, 0xAD, UInt8(order)])),
                    .text("12345678901234567890123456789012345678")
                ]
                let insert = try #require(driver.generateIdentityPreservingInsert(
                    table: table, schema: nil, columns: Self.columns, primaryKeyColumns: Self.keys, rows: [row]
                )?.first)
                _ = try await driver.executeParameterized(query: insert.statement, parameters: insert.parameters)
            }
        }
    }

    func tearDown() async {
        _ = try? await driver.execute(query: #"DeleteTable {"TableName": "\#(table)"}"#)
        driver.disconnect()
    }

    func browse(
        _ filters: [PluginQueryFilter],
        logic: String = "and",
        sort: [(columnIndex: Int, ascending: Bool)] = [],
        columns: [String] = [],
        limit: Int = 1_000,
        offset: Int = 0,
        kinds: [String: PluginColumnKind] = [:]
    ) async throws -> PluginQueryResult {
        let statement = try #require(driver.buildFilteredQuery(
            table: table, schema: nil, queryFilters: filters, logicMode: logic, sortColumns: sort,
            columns: columns, limit: limit, offset: offset, columnKinds: kinds
        ))
        return try #require(try await driver.executeBoundedQuery(query: statement, rowCap: 10_000))
    }

    func item(_ customer: String, _ order: Int) async throws -> [String: PluginCellValue] {
        let result = try await driver.execute(query: #"GetItem {"TableName": "\#(table)", "Key": {"customer": {"S": "\#(customer)"}, "orderId": {"N": "\#(order)"}}}"#)
        return Dictionary(uniqueKeysWithValues: zip(result.columns, result.rows.first ?? []))
    }
}

private func text(_ cell: PluginCellValue?) -> String? {
    guard case .text(let value) = cell else { return nil }
    return value
}

@Suite("DynamoDB Local integration", .enabled(if: DynamoDBTestLocal.isReachable), .serialized)
struct DynamoDBLocalIntegrationTests {
    @Test("A grid insert keeps a zip code a String and a 38-digit value exact")
    func insertKeepsTypes() async throws {
        let fixture = try await OrdersFixture.make()
        let row = try await fixture.item("c1", 4)
        await fixture.tearDown()
        #expect(text(row["zip"]) == "02134")
        #expect(text(row["big"]) == "12345678901234567890123456789012345678")
        #expect(row["bin"] == .bytes(Data([0xDE, 0xAD, 4])))
    }

    @Test("Pages cover every item exactly once without re-reading earlier pages")
    func pagesCoverEveryItem() async throws {
        let fixture = try await OrdersFixture.make()
        var keys = Set<String>()
        var columns: [String] = []
        for page in 0..<3 {
            let result = try await fixture.browse([], columns: columns, limit: 50, offset: page * 50)
            columns = result.columns
            for row in result.rows { keys.insert("\(row[0])|\(row[1])") }
        }
        await fixture.tearDown()
        #expect(keys.count == 120)
        #expect(Array(columns.prefix(2)) == ["customer", "orderId"])
    }

    @Test("A partition key with a sort key range becomes a Query sorted by the sort key")
    func queryOnTableKeys() async throws {
        let fixture = try await OrdersFixture.make()
        let result = try await fixture.browse(
            [PluginQueryFilter(column: "customer", op: "=", value: "c2"), PluginQueryFilter(column: "orderId", op: ">=", value: "30")],
            sort: [(columnIndex: 1, ascending: false)],
            columns: ["customer", "orderId"]
        )
        await fixture.tearDown()
        #expect(result.rows.compactMap { text($0[1]) } == (30...39).reversed().map(String.init))
        #expect(result.statusMessage?.contains("Query on the table") == true)
    }

    @Test("A filter on a global index key queries that index")
    func queryOnGlobalIndex() async throws {
        let fixture = try await OrdersFixture.make()
        let result = try await fixture.browse([
            PluginQueryFilter(column: "status", op: "=", value: "FAILED"),
            PluginQueryFilter(column: "total", op: "BETWEEN", value: "100,200", secondValue: "200", elementScope: nil)
        ])
        await fixture.tearDown()
        #expect(result.rows.count == 9)
        #expect(result.statusMessage?.contains("byStatus") == true)
    }

    @Test("An OR that names a partition key still returns matches from other partitions")
    func orKeepsOtherPartitions() async throws {
        let fixture = try await OrdersFixture.make()
        let result = try await fixture.browse(
            [PluginQueryFilter(column: "customer", op: "=", value: "c1"), PluginQueryFilter(column: "status", op: "=", value: "FAILED")],
            logic: "or"
        )
        await fixture.tearDown()
        #expect(result.rows.count == 60)
    }

    struct OperatorCase: Sendable, CustomStringConvertible {
        let op: String
        let value: String
        let expected: Int
        var description: String { op }
    }

    @Test("Every filter-bar operator matches what it names", arguments: [
        OperatorCase(op: "IS NULL", value: "", expected: 0),
        OperatorCase(op: "IS NOT NULL", value: "", expected: 120),
        OperatorCase(op: "IN", value: "FAILED, PAID", expected: 120),
        OperatorCase(op: "NOT IN", value: "FAILED", expected: 90),
        OperatorCase(op: "CONTAINS", value: "AIL", expected: 30),
        OperatorCase(op: "NOT CONTAINS", value: "AIL", expected: 90),
        OperatorCase(op: "STARTS WITH", value: "PA", expected: 90),
        OperatorCase(op: "ENDS WITH", value: "ED", expected: 30),
        OperatorCase(op: "REGEX", value: "^F.*D$", expected: 30),
        OperatorCase(op: "!=", value: "PAID", expected: 30)
    ])
    func operators(_ testCase: OperatorCase) async throws {
        let fixture = try await OrdersFixture.make()
        let result = try await fixture.browse([PluginQueryFilter(column: "status", op: testCase.op, value: testCase.value)])
        await fixture.tearDown()
        #expect(result.rows.count == testCase.expected)
    }

    @Test("Filtered pages fill up and cover every match")
    func filteredPagesFill() async throws {
        let fixture = try await OrdersFixture.make()
        var keys = Set<String>()
        for page in 0..<5 {
            let result = try await fixture.browse(
                [PluginQueryFilter(column: "status", op: "=", value: "FAILED")], limit: 7, offset: page * 7
            )
            for row in result.rows { keys.insert("\(row[0])|\(row[1])") }
        }
        let exact = try await fixture.driver.fetchExactRowCount(
            table: fixture.table, schema: nil,
            queryFilters: [PluginQueryFilter(column: "status", op: "=", value: "FAILED")], logicMode: "and"
        )
        await fixture.tearDown()
        #expect(keys.count == 30)
        #expect(exact == 30)
    }

    @Test("An edit keeps each attribute's type, removes a cleared one, and refuses a stale edit")
    func editKeepsTypes() async throws {
        let fixture = try await OrdersFixture.make()
        _ = try await fixture.driver.execute(query: #"UpdateItem {"TableName": "\#(fixture.table)", "Key": {"customer": {"S": "c1"}, "orderId": {"N": "4"}}, "UpdateExpression": "SET tags = :ss", "ExpressionAttributeValues": {":ss": {"SS": ["x", "y"]}}}"#)
        let loaded = try await fixture.browse(
            [PluginQueryFilter(column: "customer", op: "=", value: "c1"), PluginQueryFilter(column: "orderId", op: "=", value: "4")]
        )
        let row = try #require(loaded.rows.first)
        let index = { (name: String) in loaded.columns.firstIndex(of: name) ?? 0 }
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [
                (columnIndex: index("total"), columnName: "total", oldValue: row[index("total")], newValue: .text("999")),
                (columnIndex: index("tags"), columnName: "tags", oldValue: row[index("tags")], newValue: .text(#"["x","y","z"]"#)),
                (columnIndex: index("zip"), columnName: "zip", oldValue: row[index("zip")], newValue: .null)
            ],
            originalRow: row
        )
        let statements = try #require(fixture.driver.generateStatements(
            table: fixture.table, columns: loaded.columns, primaryKeyColumns: OrdersFixture.keys, changes: [change],
            insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ))
        for statement in statements {
            _ = try await fixture.driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        }
        let after = try await fixture.driver.execute(query: #"GetItem {"TableName": "\#(fixture.table)", "Key": {"customer": {"S": "c1"}, "orderId": {"N": "4"}}}"#)
        var staleError: Error?
        do {
            for statement in statements {
                _ = try await fixture.driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
            }
        } catch {
            staleError = error
        }
        await fixture.tearDown()
        let types = Dictionary(uniqueKeysWithValues: zip(after.columns, after.columnTypeNames))
        #expect(types["total"] == "Number")
        #expect(types["tags"] == "String Set")
        #expect(!after.columns.contains("zip"))
        #expect(staleError?.localizedDescription.contains("changed after it was loaded") == true)
    }

    @Test("A delete reports one item, then none")
    func deleteReportsCount() async throws {
        let fixture = try await OrdersFixture.make()
        let loaded = try await fixture.browse(
            [PluginQueryFilter(column: "customer", op: "=", value: "c3"), PluginQueryFilter(column: "orderId", op: "=", value: "7")]
        )
        let original = try #require(loaded.rows.first)
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: original)
        let statement = try #require(fixture.driver.generateStatements(
            table: fixture.table, columns: loaded.columns, primaryKeyColumns: OrdersFixture.keys, changes: [change],
            insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )?.first)
        let first = try await fixture.driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        let second = try await fixture.driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        await fixture.tearDown()
        #expect(first.rowsAffected == 1)
        #expect(second.rowsAffected == 0)
    }

    @Test("A stream carries an attribute that only the last item has")
    func streamKeepsLateAttributes() async throws {
        let fixture = try await OrdersFixture.make()
        _ = try await fixture.driver.execute(query: #"UpdateItem {"TableName": "\#(fixture.table)", "Key": {"customer": {"S": "c3"}, "orderId": {"N": "39"}}, "UpdateExpression": "SET late = :v", "ExpressionAttributeValues": {":v": {"S": "only here"}}}"#)
        var columns: [String] = []
        var rows = 0
        for try await element in fixture.driver.streamRows(query: try #require(fixture.driver.defaultExportQuery(table: fixture.table))) {
            switch element {
            case .header(let header): columns = header.columns
            case .rows(let batch): rows += batch.count
            }
        }
        await fixture.tearDown()
        #expect(columns.contains("late"))
        #expect(rows == 120)
    }

    @Test("PartiQL reads every page, honours LIMIT, and sorts a complete result")
    func partiQLReads() async throws {
        let fixture = try await OrdersFixture.make()
        let limited = try await fixture.driver.executeBoundedQuery(
            query: #"SELECT * FROM "\#(fixture.table)" WHERE status = 'FAILED' LIMIT 5"#, rowCap: 1_000
        )
        let projected = try await fixture.driver.executeBoundedQuery(
            query: #"SELECT customer FROM "\#(fixture.table)" WHERE status = 'FAILED'"#, rowCap: 1_000
        )
        let sorted = try await fixture.driver.executeBoundedQuery(
            query: #"SELECT * FROM "\#(fixture.table)" WHERE customer = 'c2' ORDER BY "total" DESC"#, rowCap: 1_000
        )
        await fixture.tearDown()
        #expect(limited?.rows.count == 5)
        #expect(projected?.rows.count == 30)
        #expect(projected?.columns == ["customer"])
        let totalIndex = try #require(sorted?.columns.firstIndex(of: "total"))
        let totals = (sorted?.rows ?? []).compactMap { text($0[totalIndex]).flatMap(Int.init) }
        #expect(totals.count == 40)
        #expect(totals == totals.sorted(by: >))
    }

    @Test("Structure: executable DDL, indexes, nested paths, and a new global index")
    func structure() async throws {
        let fixture = try await OrdersFixture.make()
        let ddl = try await fixture.driver.fetchTableDDL(table: fixture.table, schema: nil)
        let indexes = try await fixture.driver.fetchIndexes(table: fixture.table, schema: nil)
        let paths = try await fixture.driver.sampleFieldPaths(table: fixture.table, schema: nil, limit: 20)
        let addIndex = try #require(fixture.driver.generateAddIndexSQL(
            table: fixture.table, index: PluginIndexDefinition(name: "byZip", columns: ["zip"], isUnique: false)
        ))
        _ = try await fixture.driver.execute(query: addIndex)
        let afterAdd = try await fixture.driver.fetchIndexes(table: fixture.table, schema: nil)
        await fixture.tearDown()
        #expect(ddl.hasPrefix("CreateTable {"))
        #expect(indexes.map(\.name) == ["PRIMARY", "byStatus"])
        #expect(paths.contains { $0.path == "doc.a.b" })
        #expect(afterAdd.contains { $0.name == "byZip" })
    }

    @Test("A batch with one failing statement reports the failure, not success")
    func batchReportsPartialFailure() async throws {
        let fixture = try await OrdersFixture.make()
        let statement = #"BatchExecuteStatement {"Statements": [{"Statement": "INSERT INTO \"\#(fixture.table)\" VALUE {'customer': 'c9', 'orderId': 1}"}, {"Statement": "INSERT INTO \"\#(fixture.table)\" VALUE {'customer': 'c1', 'orderId': 1}"}]}"#
        var failure: Error?
        do {
            _ = try await fixture.driver.execute(query: statement)
        } catch {
            failure = error
        }
        await fixture.tearDown()
        #expect(failure?.localizedDescription.contains("1 of 2") == true)
    }
}
