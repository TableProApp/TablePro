//
//  DynamoDBDriverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

final class DynamoDBScriptedTransport: DynamoDBTransport, @unchecked Sendable {
    struct Call: Sendable {
        let action: String
        let body: DynamoDBJSON
    }

    enum Reply: Sendable {
        case json(String)
        case failure(status: Int, type: String, message: String)
    }

    typealias Handler = @Sendable (_ action: String, _ body: DynamoDBJSON, _ attempt: Int) -> Reply

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [Call] = []
    private var attempts: [String: Int] = [:]

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func bodies(of action: String) -> [DynamoDBJSON] {
        calls.filter { $0.action == action }.map(\.body)
    }

    func count(of action: String) -> Int {
        lock.withLock { attempts[action] ?? 0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let target = request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
        let action = target.split(separator: ".").last.map(String.init) ?? target
        let body = try DynamoDBJSON.parse(request.httpBody ?? Data())
        let attempt = lock.withLock { () -> Int in
            recorded.append(Call(action: action, body: body))
            attempts[action, default: 0] += 1
            return attempts[action] ?? 1
        }
        let status: Int
        let text: String
        switch handler(action, body, attempt) {
        case .json(let json):
            status = 200
            text = json
        case .failure(let code, let type, let message):
            status = code
            text = #"{"__type":"com.amazonaws.dynamodb.v20120810#\#(type)","message":"\#(message)"}"#
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-amz-json-1.0"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (Data(text.utf8), response)
    }

    func invalidate() {}
}

enum DynamoDBDriverFixture {
    static func driver(_ transport: DynamoDBScriptedTransport) async throws -> DynamoDBPluginDriver {
        let config = DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: ["awsAuthMethod": "local", "awsRegion": "us-east-1"]
        )
        let driver = DynamoDBPluginDriver(config: config, catalog: DynamoDBCatalog()) { endpoint, credentials in
            DynamoDBClient(
                endpoint: endpoint,
                credentials: credentials,
                transport: transport,
                retryPolicy: DynamoDBRetryPolicy(random: { 0 }),
                sleep: { _ in }
            )
        }
        try await driver.connect()
        return driver
    }

    static let orders = describe()

    static func describe(provisioned: Bool = false) -> String {
        let billing = provisioned
            ? #""ProvisionedThroughput":{"ReadCapacityUnits":5,"WriteCapacityUnits":7}"#
            : #""BillingModeSummary":{"BillingMode":"PAY_PER_REQUEST"}"#
        return #"""
            {"Table":{"TableName":"orders","TableStatus":"ACTIVE",
            "KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}],
            "AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"},{"AttributeName":"sk","AttributeType":"N"},
            {"AttributeName":"status","AttributeType":"S"},{"AttributeName":"total","AttributeType":"N"}],
            "GlobalSecondaryIndexes":[{"IndexName":"byStatus","IndexStatus":"ACTIVE",
            "KeySchema":[{"AttributeName":"status","KeyType":"HASH"},{"AttributeName":"total","KeyType":"RANGE"}],
            "Projection":{"ProjectionType":"ALL"}}],
            \#(billing)}}
            """#
    }

    static func item(_ pk: String, _ sk: Int, _ extra: String = "") -> String {
        #"{"pk":{"S":"\#(pk)"},"sk":{"N":"\#(sk)"}\#(extra)}"#
    }

    static func key(_ pk: String, _ sk: Int) -> String {
        item(pk, sk)
    }

    static func startIndex(_ body: DynamoDBJSON) -> Int? {
        body["ExclusiveStartKey"]?["sk"]?["N"]?.stringValue.flatMap(Int.init)
    }

    static func text(_ cell: PluginCellValue?) -> String? {
        guard case .text(let value)? = cell else { return nil }
        return value
    }

    static func column(_ name: String, of result: PluginQueryResult) -> [String?] {
        guard let index = result.columns.firstIndex(of: name) else { return [] }
        return result.rows.map { text($0[index]) }
    }
}

@Suite("DynamoDB driver over a scripted transport")
struct DynamoDBDriverTests {
    private typealias Fixture = DynamoDBDriverFixture

    // MARK: - Streaming

    @Test("A stream delivers every row of every page to a consumer that starts late")
    func streamDeliversEveryRow() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let from = (Fixture.startIndex(body) ?? -1) + 1
                let isLast = from + 1_000 >= 12_000
                let items = (from..<(from + 1_000)).map { index in
                    Fixture.item("p", index, index == 11_999 ? #","late":{"S":"x"}"# : "")
                }
                let next = isLast ? "" : #","LastEvaluatedKey":\#(Fixture.key("p", from + 999))"#
                return .json(#"{"Items":[\#(items.joined(separator: ","))]\#(next)}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let query = try #require(driver.defaultExportQuery(table: "orders"))

        let stream = driver.streamRows(query: query)
        try await Task.sleep(nanoseconds: 200_000_000)
        var columns: [String] = []
        var rowCount = 0
        for try await element in stream {
            switch element {
            case .header(let header): columns = header.columns
            case .rows(let rows): rowCount += rows.count
            }
        }

        #expect(rowCount == 12_000)
        #expect(columns.contains("late"))
    }

    @Test("A stream applies ORDER BY and OFFSET, and OFFSET without LIMIT does not trap")
    func streamAppliesWindow() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let items = [2, 3, 1, 5].enumerated().map { index, value in
                    Fixture.item("p", index, #","v":{"N":"\#(value)"}"#)
                }
                return .json(#"{"Items":[\#(items.joined(separator: ","))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)

        let sorted = try await Self.collect(driver.streamRows(query: #"Scan {"TableName":"orders"} ORDER BY "v" DESC"#))
        let skipped = try await Self.collect(driver.streamRows(query: #"Scan {"TableName":"orders"} OFFSET 1"#))

        #expect(sorted.column("v") == ["5", "3", "2", "1"])
        #expect(skipped.rows.count == 3)
    }

    @Test("A stream finishes while another reader in the process waits on a quiet pipe")
    func streamIgnoresABlockedAsyncBytesReader() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                return .json(#"{"Items":[\#(Fixture.item("p", 0)),\#(Fixture.item("p", 1))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let query = try #require(driver.defaultExportQuery(table: "orders"))
        let pipe = Pipe()
        let blocker = Task {
            for try await _ in pipe.fileHandleForReading.bytes {}
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let result = try? await Self.collect(driver.streamRows(query: query))
                return result?.rows.count == 2
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            try? pipe.fileHandleForWriting.close()
            group.cancelAll()
            return first
        }
        blocker.cancel()

        #expect(finished)
    }

    // MARK: - Paging

    @Test("An empty filtered page that still has a LastEvaluatedKey is not the end")
    func filteredPagesKeepReading() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                guard Fixture.startIndex(body) != nil else {
                    return .json(#"{"Items":[],"LastEvaluatedKey":\#(Fixture.key("p", 1))}"#)
                }
                return .json(#"{"Items":[\#(Fixture.item("p", 2, #","v":{"N":"5"}"#))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let query = try #require(driver.buildFilteredQuery(
            table: "orders", schema: nil,
            queryFilters: [PluginQueryFilter(column: "v", op: "=", value: "5")], logicMode: "AND",
            sortColumns: [], columns: [], limit: 10, offset: 0, columnKinds: [:]
        ))

        let result = try await driver.execute(query: query)

        let scans = transport.bodies(of: "Scan")
        #expect(result.rows.count == 1)
        #expect(scans.count == 2)
        #expect(scans.first?["Limit"] == nil)
        #expect(scans.last.flatMap(Fixture.startIndex) == 1)
    }

    @Test("The next page starts from the key where the previous one stopped")
    func nextPageResumes() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let from = (Fixture.startIndex(body) ?? -1) + 1
                let limit = body["Limit"]?.intValue ?? 5
                let end = min(from + limit, 5)
                let items = (from..<end).map { Fixture.item("p", $0) }
                let next = end < 5 ? #","LastEvaluatedKey":\#(Fixture.key("p", end - 1))"# : ""
                return .json(#"{"Items":[\#(items.joined(separator: ","))]\#(next)}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let first = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 0))
        let second = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 2))

        let firstPage = try await driver.execute(query: first)
        let scansBefore = transport.count(of: "Scan")
        let secondPage = try await driver.execute(query: second)

        let scans = transport.bodies(of: "Scan")
        #expect(firstPage.column("sk") == ["0", "1"])
        #expect(secondPage.column("sk") == ["2", "3"])
        #expect(scans.first?["Limit"] == .number("2"))
        #expect(transport.count(of: "Scan") == scansBefore + 1)
        #expect(scans.last.flatMap(Fixture.startIndex) == 1)
    }

    @Test("Rows are sorted before the row cap cuts them")
    func sortsBeforeTruncating() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let items = [2, 3, 1, 5].enumerated().map { index, value in
                    Fixture.item("p", index, #","v":{"N":"\#(value)"}"#)
                }
                return .json(#"{"Items":[\#(items.joined(separator: ","))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)

        let result = try await driver.executeUserQuery(
            query: #"Scan {"TableName":"orders"} ORDER BY "v" DESC"#, rowCap: 3, parameters: nil
        )

        #expect(result.column("v") == ["5", "3", "2"])
        #expect(result.isTruncated)
    }

    @Test("A write forgets where the table's pages start")
    func writeForgetsReadPositions() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let from = (Fixture.startIndex(body) ?? -1) + 1
                let limit = body["Limit"]?.intValue ?? 5
                let end = min(from + limit, 5)
                let items = (from..<end).map { Fixture.item("p", $0) }
                let next = end < 5 ? #","LastEvaluatedKey":\#(Fixture.key("p", end - 1))"# : ""
                return .json(#"{"Items":[\#(items.joined(separator: ","))]\#(next)}"#)
            case "PutItem":
                return .json("{}")
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let first = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 0))
        let second = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 2))
        _ = try await driver.execute(query: first)

        _ = try await driver.execute(query: #"PutItem {"TableName":"orders","Item":\#(Fixture.item("p", 9))}"#)
        let scansBefore = transport.count(of: "Scan")
        _ = try await driver.execute(query: second)

        let afterWrite = transport.bodies(of: "Scan").dropFirst(scansBefore)
        #expect(!afterWrite.isEmpty)
        #expect(afterWrite.first.flatMap(Fixture.startIndex) == nil)
    }

    // MARK: - Batches

    @Test("Keys still unread after 10 attempts are reported against every key asked for")
    func batchGetReportsRequestedTotal() async throws {
        let transport = DynamoDBScriptedTransport { action, _, attempt in
            guard action == "BatchGetItem" else { return .json(#"{"TableNames":[]}"#) }
            let found = attempt == 1 ? "\(Fixture.item("p", 1)),\(Fixture.item("p", 2))" : ""
            let unread = #"{"orders":{"Keys":[\#(Fixture.key("p", 3))]}}"#
            return .json(#"{"Responses":{"orders":[\#(found)]},"UnprocessedKeys":\#(unread)}"#)
        }
        let driver = try await Fixture.driver(transport)
        let keys = [1, 2, 3].map { Fixture.key("p", $0) }.joined(separator: ",")

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.execute(query: #"BatchGetItem {"RequestItems":{"orders":{"Keys":[\#(keys)]}}}"#)
        }

        guard case .partialBatch(let applied, let total, _)? = error else {
            Issue.record("Expected a partial batch, got \(String(describing: error))")
            return
        }
        #expect(applied == 2)
        #expect(total == 3)
    }

    @Test("BatchGetItem sends unprocessed keys again and returns items in the order the keys were asked for")
    func batchGetRetriesAndOrders() async throws {
        let transport = DynamoDBScriptedTransport { action, _, attempt in
            guard action == "BatchGetItem" else { return .json(#"{"TableNames":[]}"#) }
            if attempt == 1 {
                return .json(#"""
                    {"Responses":{"orders":[\#(Fixture.item("p", 3)),\#(Fixture.item("p", 1))]},
                    "UnprocessedKeys":{"orders":{"Keys":[\#(Fixture.key("p", 2))]}}}
                    """#)
            }
            return .json(#"{"Responses":{"orders":[\#(Fixture.item("p", 2))]},"UnprocessedKeys":{}}"#)
        }
        let driver = try await Fixture.driver(transport)
        let keys = [1, 2, 3].map { Fixture.key("p", $0) }.joined(separator: ",")

        let result = try await driver.execute(query: #"BatchGetItem {"RequestItems":{"orders":{"Keys":[\#(keys)]}}}"#)

        let requests = transport.bodies(of: "BatchGetItem")
        #expect(result.column("sk") == ["1", "2", "3"])
        #expect(requests.count == 2)
        #expect(requests.last?["RequestItems"]?["orders"]?["Keys"]?.arrayValue?.count == 1)
    }

    @Test("BatchWriteItem sends unprocessed items again until DynamoDB takes them")
    func batchWriteRetriesUntilDone() async throws {
        let transport = DynamoDBScriptedTransport { action, _, attempt in
            guard action == "BatchWriteItem" else { return .json(#"{"TableNames":[]}"#) }
            guard attempt == 1 else { return .json(#"{"UnprocessedItems":{}}"#) }
            return .json(#"{"UnprocessedItems":{"orders":[{"PutRequest":{"Item":\#(Fixture.item("p", 2))}}]}}"#)
        }
        let driver = try await Fixture.driver(transport)

        let result = try await driver.execute(query: Self.batchWrite)

        #expect(result.rowsAffected == 2)
        #expect(transport.count(of: "BatchWriteItem") == 2)
    }

    @Test("BatchWriteItem reports what is still unprocessed after 10 attempts as a failure")
    func batchWriteGivesUp() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            guard action == "BatchWriteItem" else { return .json(#"{"TableNames":[]}"#) }
            return .json(#"{"UnprocessedItems":{"orders":[{"PutRequest":{"Item":\#(Fixture.item("p", 2))}}]}}"#)
        }
        let driver = try await Fixture.driver(transport)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.execute(query: Self.batchWrite)
        }

        guard case .partialBatch(let applied, let total, _)? = error else {
            Issue.record("Expected a partial batch, got \(String(describing: error))")
            return
        }
        #expect(applied == 1)
        #expect(total == 2)
        #expect(transport.count(of: "BatchWriteItem") == 10)
    }

    // MARK: - Counts

    @Test("A COUNT request adds up every page")
    func countRequestSumsPages() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            guard action == "Scan" else { return .json(#"{"TableNames":[]}"#) }
            guard Fixture.startIndex(body) != nil else {
                return .json(#"{"Count":3,"ScannedCount":3,"LastEvaluatedKey":\#(Fixture.key("p", 1))}"#)
            }
            return .json(#"{"Count":4,"ScannedCount":5}"#)
        }
        let driver = try await Fixture.driver(transport)

        let result = try await driver.execute(query: #"Scan {"TableName":"orders","Select":"COUNT"}"#)

        #expect(result.column("Count") == ["7"])
        #expect(result.column("ScannedCount") == ["8"])
    }

    @Test("Count Exactly keeps an attribute name with a dot in it as one name")
    func exactCountKeepsDottedName() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan" where body["Select"]?.stringValue == "COUNT":
                guard Fixture.startIndex(body) != nil else {
                    return .json(#"{"Count":2,"ScannedCount":9,"LastEvaluatedKey":\#(Fixture.key("p", 1))}"#)
                }
                return .json(#"{"Count":3,"ScannedCount":9}"#)
            case "Scan":
                return .json(#"{"Items":[\#(Fixture.item("p", 0, #","a.b":{"N":"1"}"#))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let browse = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 10, offset: 0))
        _ = try await driver.execute(query: browse)

        let count = try await driver.fetchExactRowCount(
            table: "orders", schema: nil,
            queryFilters: [PluginQueryFilter(column: "a.b", op: "=", value: "1")], logicMode: "AND"
        )

        let countScan = try #require(transport.bodies(of: "Scan").first { $0["Select"]?.stringValue == "COUNT" })
        let names = countScan["ExpressionAttributeNames"]?.objectValue?.values.compactMap(\.stringValue) ?? []
        #expect(count == 5)
        #expect(names == ["a.b"])
    }

    // MARK: - Writes

    @Test("An edited value is bound with the type the item holds now")
    func updateBindsCurrentTypes() async throws {
        let transport = Self.writeTransport(execute: .json(#"{"Items":[]}"#))
        let driver = try await Fixture.driver(transport)
        let statement = try Self.updateStatement(driver)

        _ = try await driver.executeParameterized(query: statement.statement, parameters: statement.parameters)

        let sent = try #require(transport.bodies(of: "ExecuteStatement").first)
        #expect(sent["Parameters"]?.arrayValue?.first == .object(["N": .string("2")]))
    }

    @Test("An update DynamoDB's condition refuses is reported as a changed item")
    func updateConflictIsItemChanged() async throws {
        let transport = Self.writeTransport(
            execute: .failure(status: 400, type: "ConditionalCheckFailedException", message: "The conditional request failed")
        )
        let driver = try await Fixture.driver(transport)
        let statement = try Self.updateStatement(driver)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        }

        guard case .itemChanged? = error else {
            Issue.record("Expected itemChanged, got \(String(describing: error))")
            return
        }
    }

    @Test("An update of an item that no longer exists is refused before it is sent")
    func updateOfMissingItemIsItemMissing() async throws {
        let transport = Self.writeTransport(currentItem: "{}", execute: .json(#"{"Items":[]}"#))
        let driver = try await Fixture.driver(transport)
        let statement = try Self.updateStatement(driver)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        }

        guard case .itemMissing? = error else {
            Issue.record("Expected itemMissing, got \(String(describing: error))")
            return
        }
        #expect(transport.count(of: "ExecuteStatement") == 0)
    }

    @Test("An insert of a key that already exists says so")
    func duplicateInsertIsReported() async throws {
        let transport = Self.writeTransport(
            execute: .failure(status: 400, type: "DuplicateItemException", message: "Duplicate primary key exists in table")
        )
        let driver = try await Fixture.driver(transport)
        let statement = try #require(driver.generateStatements(
            table: "orders", columns: ["pk", "sk", "v"], primaryKeyColumns: ["pk", "sk"],
            changes: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
            insertedRowData: [0: [.text("p"), .text("1"), .text("x")]], deletedRowIndices: [], insertedRowIndices: [0]
        )?.first)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        }

        #expect(error?.localizedDescription == String(localized: "An item with this key already exists"))
    }

    @Test("An insert with no value for a key is refused before it is sent")
    func insertWithoutKeyIsRefused() async throws {
        let transport = Self.writeTransport(execute: .json(#"{"Items":[]}"#))
        let driver = try await Fixture.driver(transport)
        let statement = try #require(driver.generateStatements(
            table: "orders", columns: ["pk", "sk", "v"], primaryKeyColumns: ["pk", "sk"],
            changes: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
            insertedRowData: [0: [.text("__DEFAULT__"), .text("1"), .text("x")]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )?.first)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.executeParameterized(query: statement.statement, parameters: statement.parameters)
        }

        guard case .invalidValue(let attribute, _)? = error else {
            Issue.record("Expected invalidValue, got \(String(describing: error))")
            return
        }
        #expect(attribute == "pk")
        #expect(transport.count(of: "ExecuteStatement") == 0)
    }

    // MARK: - Request completion

    @Test("A global index created on a provisioned table gets its key type and the table's capacity")
    func globalIndexCreationIsCompleted() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.describe(provisioned: true))
            case "Scan":
                return .json(#"{"Items":[\#(Fixture.item("p", 0, #","amount":{"N":"9"}"#))]}"#)
            case "UpdateTable":
                return .json(#"{"TableDescription":{"TableStatus":"UPDATING"}}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let statement = try #require(driver.generateAddIndexSQL(
            table: "orders", index: PluginIndexDefinition(name: "byAmount", columns: ["amount"])
        ))

        _ = try await driver.execute(query: statement)

        let sent = try #require(transport.bodies(of: "UpdateTable").first)
        let definitions = sent["AttributeDefinitions"]?.arrayValue ?? []
        let create = sent["GlobalSecondaryIndexUpdates"]?.arrayValue?.first?["Create"]
        #expect(definitions.contains(.object(["AttributeName": .string("amount"), "AttributeType": .string("N")])))
        #expect(create?["ProvisionedThroughput"]?["ReadCapacityUnits"] == .number("5"))
        #expect(create?["ProvisionedThroughput"]?["WriteCapacityUnits"] == .number("7"))
    }

    @Test("Turning Time to Live off names the attribute it was on")
    func timeToLiveOffNamesAttribute() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTimeToLive":
                return .json(#"{"TimeToLiveDescription":{"TimeToLiveStatus":"ENABLED","AttributeName":"expiresAt"}}"#)
            case "UpdateTimeToLive":
                return .json(#"{"TimeToLiveSpecification":{"Enabled":false,"AttributeName":"expiresAt"}}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let statement = try #require(driver.maintenanceStatements(
            operation: DynamoDBPluginDriver.MaintenanceName.timeToLiveOff, table: "orders", schema: nil, options: [:]
        )?.first)

        _ = try await driver.execute(query: statement)

        let sent = try #require(transport.bodies(of: "UpdateTimeToLive").first)
        #expect(sent["TimeToLiveSpecification"]?["AttributeName"] == .string("expiresAt"))
        #expect(sent["TimeToLiveSpecification"]?["Enabled"] == .bool(false))
    }

    // MARK: - PartiQL ORDER BY

    @Test("ORDER BY on the sort key of a fixed partition goes to DynamoDB on its own line")
    func orderBySortKeyIsSent() async throws {
        let transport = Self.partiQLTransport(items: [1, 2])
        let driver = try await Fixture.driver(transport)

        _ = try await driver.execute(query: "SELECT * FROM \"orders\" WHERE \"pk\" = 'p' -- note\nORDER BY \"sk\" DESC")

        let statement = try #require(transport.bodies(of: "ExecuteStatement").first?["Statement"]?.stringValue)
        #expect(statement.components(separatedBy: "\n").last == "ORDER BY \"sk\" DESC")
    }

    @Test(
        "ORDER BY is applied to the result when DynamoDB would sort each partition on its own or reject it",
        arguments: [
            "SELECT * FROM \"orders\" WHERE \"pk\" IN ['p', 'q'] ORDER BY \"sk\" DESC",
            "SELECT * FROM \"orders\".\"byStatus\" WHERE \"status\" = 'open' ORDER BY \"sk\" DESC",
            "SELECT * FROM \"orders\" WHERE \"pk\" = 'p' OR \"pk\" = 'q' ORDER BY \"sk\" DESC"
        ]
    )
    func orderByIsAppliedLocally(query: String) async throws {
        let transport = Self.partiQLTransport(items: [1, 5, 3])
        let driver = try await Fixture.driver(transport)

        let result = try await driver.execute(query: query)

        let statement = try #require(transport.bodies(of: "ExecuteStatement").first?["Statement"]?.stringValue)
        #expect(!statement.contains("ORDER BY"))
        #expect(result.column("sk") == ["5", "3", "1"])
    }

    @Test("A SELECT cut off by the row cap is not sorted as if it were the whole result")
    func partialPartiQLResultIsNotSorted() async throws {
        let transport = DynamoDBScriptedTransport { action, _, attempt in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "ExecuteStatement" where attempt == 1:
                let rows = [2, 3, 1].enumerated().map { index, value in
                    Fixture.item("p", index, #","v":{"N":"\#(value)"}"#)
                }
                return .json(#"{"Items":[\#(rows.joined(separator: ","))],"NextToken":"more"}"#)
            case "ExecuteStatement":
                return .json(#"{"Items":[\#(Fixture.item("p", 3, #","v":{"N":"5"}"#))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)

        let result = try await driver.executeUserQuery(
            query: "SELECT * FROM \"orders\" ORDER BY \"v\" DESC", rowCap: 1, parameters: nil
        )

        #expect(result.column("v") == ["2"])
        #expect(result.isTruncated)
        #expect(result.statusMessage?.contains("v") == true)
    }

    @Test("LIMIT 0 reads nothing")
    func limitZeroReadsNothing() async throws {
        let transport = Self.partiQLTransport(items: [1, 2])
        let driver = try await Fixture.driver(transport)

        let result = try await driver.execute(query: "SELECT * FROM \"orders\" LIMIT 0")

        #expect(result.rows.isEmpty)
        #expect(transport.count(of: "ExecuteStatement") == 0)
    }

    @Test("A local index and the primary key are reported with a type the drop refusal reads back")
    func indexTypesNameTheirKind() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            guard action == "DescribeTable" else { return .json(#"{"TableNames":[]}"#) }
            return .json(#"""
                {"Table":{"TableName":"orders","TableStatus":"ACTIVE",
                "KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}],
                "AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"},{"AttributeName":"sk","AttributeType":"N"},
                {"AttributeName":"total","AttributeType":"N"}],
                "LocalSecondaryIndexes":[{"IndexName":"byTotal",
                "KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"total","KeyType":"RANGE"}],
                "Projection":{"ProjectionType":"KEYS_ONLY"}}]}}
                """#)
        }
        let driver = try await Fixture.driver(transport)

        let indexes = try await driver.fetchIndexes(table: "orders", schema: nil)

        let local = try #require(indexes.first { $0.name == "byTotal" })
        let primary = try #require(indexes.first { $0.isPrimary })
        let localDefinition = PluginIndexDefinition(name: local.name, columns: local.columns, indexType: local.type)
        let primaryDefinition = PluginIndexDefinition(name: primary.name, columns: primary.columns, indexType: primary.type)
        #expect(driver.schemaOperationRefusal(.dropIndex(localDefinition)) != nil)
        #expect(driver.schemaOperationRefusal(.dropIndex(primaryDefinition)) != nil)
    }

    @Test("A PartiQL page asks for no more items than the read still needs")
    func partiQLPageSetsLimit() async throws {
        let transport = Self.partiQLTransport(items: [1, 2])
        let driver = try await Fixture.driver(transport)

        _ = try await driver.execute(query: "SELECT * FROM \"orders\" LIMIT 3 OFFSET 2")

        #expect(transport.bodies(of: "ExecuteStatement").first?["Limit"] == .number("5"))
    }

    @Test("An INSERT with parameters may give its key as a literal")
    func literalKeyInParameterizedInsert() async throws {
        let transport = Self.writeTransport(execute: .json(#"{"Items":[]}"#))
        let driver = try await Fixture.driver(transport)

        _ = try await driver.executeParameterized(
            query: "INSERT INTO \"orders\" VALUE {'pk': 'p', 'sk': 1, 'v': ?}", parameters: [.text("x")]
        )

        #expect(transport.count(of: "ExecuteStatement") == 1)
    }

    @Test("A table DynamoDB is still creating opens empty with a note, and is described again next time")
    func tableBeingCreated() async throws {
        let transport = DynamoDBScriptedTransport { action, _, attempt in
            switch action {
            case "DescribeTable":
                let status = attempt == 1 ? "CREATING" : "ACTIVE"
                return .json(Fixture.orders.replacingOccurrences(of: "\"ACTIVE\",\n", with: "\"\(status)\",\n"))
            case "Scan":
                return .json(#"{"Items":[\#(Fixture.item("p", 1))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let query = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 10, offset: 0))

        let creating = try await driver.execute(query: query)
        let active = try await driver.execute(query: query)

        #expect(creating.rows.isEmpty)
        #expect(creating.statusMessage != nil)
        #expect(active.rows.count == 1)
        #expect(transport.count(of: "DescribeTable") == 2)
    }

    @Test("Count Exactly is not cut short by the query timeout")
    func exactCountIgnoresQueryTimeout() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                Thread.sleep(forTimeInterval: 0.4)
                let page = Fixture.startIndex(body) ?? 0
                let next = page < 3 ? #","LastEvaluatedKey":\#(Fixture.key("p", page + 1))"# : ""
                return .json(#"{"Count":10,"ScannedCount":10\#(next)}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        try await driver.applyQueryTimeout(1)

        let count = try await driver.fetchExactRowCount(table: "orders", schema: nil, queryFilters: [], logicMode: "AND")

        #expect(count == 40)
    }

    @Test("An index key whose type no item shows is refused rather than guessed as a String")
    func unknownIndexKeyTypeIsRefused() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable": return .json(Fixture.orders)
            case "Scan": return .json(#"{"Items":[\#(Fixture.item("p", 0))]}"#)
            default: return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let statement = try #require(driver.generateAddIndexSQL(
            table: "orders", index: PluginIndexDefinition(name: "byScore", columns: ["score"])
        ))

        await #expect(throws: DynamoDBError.self) {
            try await driver.execute(query: statement)
        }
        #expect(transport.count(of: "UpdateTable") == 0)
    }

    @Test("A BatchWriteItem that gives up still forgets where the table's pages start")
    func failedBatchWriteForgetsReadPositions() async throws {
        let transport = DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let from = (Fixture.startIndex(body) ?? -1) + 1
                let end = min(from + (body["Limit"]?.intValue ?? 5), 5)
                let items = (from..<end).map { Fixture.item("p", $0) }
                let next = end < 5 ? #","LastEvaluatedKey":\#(Fixture.key("p", end - 1))"# : ""
                return .json(#"{"Items":[\#(items.joined(separator: ","))]\#(next)}"#)
            case "BatchWriteItem":
                return .json(#"{"UnprocessedItems":{"orders":[{"PutRequest":{"Item":\#(Fixture.item("p", 2))}}]}}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)
        let first = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 0))
        let second = try #require(driver.buildBrowseQuery(table: "orders", sortColumns: [], columns: [], limit: 2, offset: 2))
        _ = try await driver.execute(query: first)

        _ = try? await driver.execute(query: Self.batchWrite)
        let scansBefore = transport.count(of: "Scan")
        _ = try await driver.execute(query: second)

        let afterWrite = transport.bodies(of: "Scan").dropFirst(scansBefore)
        #expect(!afterWrite.isEmpty)
        #expect(afterWrite.first.flatMap(Fixture.startIndex) == nil)
    }

    @Test("An export keeps a column whose value is NULL on every item, and a huge LIMIT with OFFSET does not trap")
    func exportKeepsNullColumnAndHugeWindow() async throws {
        let transport = DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let items = [2, 1].enumerated().map { index, value in
                    Fixture.item("p", index, #","v":{"N":"\#(value)"},"deletedAt":{"NULL":true}"#)
                }
                return .json(#"{"Items":[\#(items.joined(separator: ","))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
        let driver = try await Fixture.driver(transport)

        let result = try await Self.collect(driver.streamRows(
            query: #"Scan {"TableName":"orders"} ORDER BY "v" ASC LIMIT 9223372036854775807 OFFSET 1"#
        ))

        #expect(result.columns.contains("deletedAt"))
        #expect(result.column("v") == ["2"])
    }

    // MARK: - Timeout and Stop

    @Test("The query timeout stops a read that keeps paging")
    func queryTimeoutStopsRead() async throws {
        let transport = Self.endlessTransport()
        let driver = try await Fixture.driver(transport)
        try await driver.applyQueryTimeout(1)

        let error = await #expect(throws: DynamoDBError.self) {
            try await driver.execute(query: Self.endlessQuery(driver))
        }

        #expect(error == .timedOut(seconds: 1))
    }

    @Test("Stop cancels a read that keeps paging, and the app reads it as a stop rather than a failure")
    func cancelStopsRead() async throws {
        let transport = Self.endlessTransport()
        let driver = try await Fixture.driver(transport)
        let query = try Self.endlessQuery(driver)
        let read = Task { try await driver.execute(query: query) }

        for _ in 0..<200 where transport.count(of: "Scan") < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try driver.cancelQuery()

        let outcome = await read.result
        guard case .failure(let error) = outcome else {
            Issue.record("The read finished instead of stopping")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: - Helpers

    private static let batchWrite = #"""
        BatchWriteItem {"RequestItems":{"orders":[
        {"PutRequest":{"Item":\#(DynamoDBDriverFixture.item("p", 1))}},
        {"PutRequest":{"Item":\#(DynamoDBDriverFixture.item("p", 2))}}]}}
        """#

    private static func collect(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> PluginQueryResult {
        var columns: [String] = []
        var rows: [[PluginCellValue]] = []
        for try await element in stream {
            switch element {
            case .header(let header): columns = header.columns
            case .rows(let batch): rows += batch
            }
        }
        return PluginQueryResult(
            columns: columns, columnTypeNames: columns.map { _ in "" }, rows: rows,
            rowsAffected: 0, timing: PluginQueryTiming(total: 0)
        )
    }

    private static func writeTransport(
        currentItem: String = #"{"Item":\#(DynamoDBDriverFixture.item("p", 1, #","v":{"N":"1"}"#))}"#,
        execute: DynamoDBScriptedTransport.Reply
    ) -> DynamoDBScriptedTransport {
        DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable": return .json(Fixture.orders)
            case "GetItem": return .json(currentItem)
            case "Scan": return .json(#"{"Items":[]}"#)
            case "ExecuteStatement": return execute
            default: return .json(#"{"TableNames":[]}"#)
            }
        }
    }

    private static func updateStatement(
        _ driver: DynamoDBPluginDriver
    ) throws -> (statement: String, parameters: [PluginCellValue]) {
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 2, columnName: "v", oldValue: .text("1"), newValue: .text("2"))],
            originalRow: [.text("p"), .text("1"), .text("1")]
        )
        return try #require(driver.generateStatements(
            table: "orders", columns: ["pk", "sk", "v"], primaryKeyColumns: ["pk", "sk"], changes: [change],
            insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )?.first)
    }

    private static func partiQLTransport(items: [Int]) -> DynamoDBScriptedTransport {
        DynamoDBScriptedTransport { action, _, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "ExecuteStatement":
                let rows = items.map { Fixture.item("p", $0, #","status":{"S":"open"},"total":{"N":"1"}"#) }
                return .json(#"{"Items":[\#(rows.joined(separator: ","))]}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
    }

    private static func endlessTransport() -> DynamoDBScriptedTransport {
        DynamoDBScriptedTransport { action, body, _ in
            switch action {
            case "DescribeTable":
                return .json(Fixture.orders)
            case "Scan":
                let next = (Fixture.startIndex(body) ?? 0) + 1
                return .json(#"{"Items":[],"LastEvaluatedKey":\#(Fixture.key("p", next))}"#)
            default:
                return .json(#"{"TableNames":[]}"#)
            }
        }
    }

    private static func endlessQuery(_ driver: DynamoDBPluginDriver) throws -> String {
        try #require(driver.buildFilteredQuery(
            table: "orders", schema: nil,
            queryFilters: [PluginQueryFilter(column: "v", op: "=", value: "5")], logicMode: "AND",
            sortColumns: [], columns: [], limit: 10, offset: 0, columnKinds: [:]
        ))
    }
}

private extension PluginQueryResult {
    func column(_ name: String) -> [String?] {
        DynamoDBDriverFixture.column(name, of: self)
    }
}
