//
//  DynamoDBAccessPlannerTests.swift
//  TableProTests
//

import Foundation
import Testing

struct DynamoDBAccessPlannerTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        let name: String
        let filters: [DynamoDBBrowseFilter]
        let matchAll: Bool
        let order: [DynamoDBOrderTerm]
        let columns: [String]

        init(
            _ name: String,
            _ filters: [DynamoDBBrowseFilter],
            matchAll: Bool = true,
            order: [DynamoDBOrderTerm] = [],
            columns: [String] = []
        ) {
            self.name = name
            self.filters = filters
            self.matchAll = matchAll
            self.order = order
            self.columns = columns
        }

        var testDescription: String { name }
    }

    static let ordersDescription = """
        {"Table": {
            "TableName": "orders",
            "KeySchema": [
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"}
            ],
            "AttributeDefinitions": [
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "N"},
                {"AttributeName": "status", "AttributeType": "S"},
                {"AttributeName": "total", "AttributeType": "N"},
                {"AttributeName": "zip", "AttributeType": "S"},
                {"AttributeName": "created", "AttributeType": "S"},
                {"AttributeName": "email", "AttributeType": "S"},
                {"AttributeName": "phone", "AttributeType": "S"}
            ],
            "GlobalSecondaryIndexes": [
                {
                    "IndexName": "byStatus",
                    "KeySchema": [
                        {"AttributeName": "status", "KeyType": "HASH"},
                        {"AttributeName": "total", "KeyType": "RANGE"}
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                    "IndexStatus": "ACTIVE"
                },
                {
                    "IndexName": "byZip",
                    "KeySchema": [{"AttributeName": "zip", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "KEYS_ONLY"},
                    "IndexStatus": "ACTIVE"
                },
                {
                    "IndexName": "byEmail",
                    "KeySchema": [{"AttributeName": "email", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "ALL"},
                    "IndexStatus": "CREATING"
                },
                {
                    "IndexName": "byPhone",
                    "KeySchema": [{"AttributeName": "phone", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "ALL"},
                    "IndexStatus": "ACTIVE",
                    "Backfilling": true
                }
            ],
            "LocalSecondaryIndexes": [
                {
                    "IndexName": "byCreated",
                    "KeySchema": [
                        {"AttributeName": "pk", "KeyType": "HASH"},
                        {"AttributeName": "created", "KeyType": "RANGE"}
                    ],
                    "Projection": {"ProjectionType": "KEYS_ONLY"}
                }
            ]
        }}
        """

    static let sessionsDescription = """
        {"Table": {
            "TableName": "sessions",
            "KeySchema": [{"AttributeName": "pk", "KeyType": "HASH"}],
            "AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}]
        }}
        """

    static let eventsDescription = """
        {"Table": {
            "TableName": "events",
            "KeySchema": [{"AttributeName": "id", "KeyType": "HASH"}],
            "AttributeDefinitions": [
                {"AttributeName": "id", "AttributeType": "S"},
                {"AttributeName": "tenant", "AttributeType": "S"},
                {"AttributeName": "region", "AttributeType": "S"},
                {"AttributeName": "year", "AttributeType": "N"},
                {"AttributeName": "month", "AttributeType": "N"}
            ],
            "GlobalSecondaryIndexes": [
                {
                    "IndexName": "byTenantRegion",
                    "KeySchema": [
                        {"AttributeName": "tenant", "KeyType": "HASH"},
                        {"AttributeName": "region", "KeyType": "HASH"},
                        {"AttributeName": "year", "KeyType": "RANGE"},
                        {"AttributeName": "month", "KeyType": "RANGE"}
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                    "IndexStatus": "ACTIVE"
                }
            ]
        }}
        """

    static func schema(_ description: String) throws -> DynamoDBTableSchema {
        try DynamoDBTableSchema(describeTableResponse: try DynamoDBJSON.parse(description))
    }

    static func filter(
        _ attribute: String,
        _ op: String,
        _ value: String = "",
        second: String? = nil,
        caseSensitive: Bool = true
    ) -> DynamoDBBrowseFilter {
        DynamoDBBrowseFilter(
            attribute: attribute, op: op, value: value, secondValue: second, kind: nil, caseSensitive: caseSensitive
        )
    }

    static func plan(
        _ filters: [DynamoDBBrowseFilter],
        matchAll: Bool = true,
        order: [DynamoDBOrderTerm] = [],
        columns: [String] = [],
        on description: String = ordersDescription
    ) throws -> DynamoDBReadPlan {
        let tableSchema = try Self.schema(description)
        let request = DynamoDBBrowseRequest(
            table: tableSchema.name, filters: filters, matchAll: matchAll, columns: columns
        )
        return try DynamoDBAccessPlanner(schema: tableSchema).plan(request, order: order)
    }

    static func text(_ key: String, in request: [String: DynamoDBJSON]) -> String? {
        request[key]?.stringValue
    }

    static func names(in request: [String: DynamoDBJSON]) -> [String: String] {
        (request["ExpressionAttributeNames"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }

    static func values(in request: [String: DynamoDBJSON]) throws -> [String: DynamoDBAttributeValue] {
        try (request["ExpressionAttributeValues"]?.objectValue ?? [:]).mapValues(DynamoDBAttributeValue.init(wireJSON:))
    }

    static func clientPredicate(_ filter: DynamoDBBrowseFilter) -> DynamoDBClientPredicate {
        DynamoDBClientPredicate(
            path: DynamoDBAttributePath(attribute: filter.attribute),
            op: filter.op,
            value: filter.value,
            secondValue: filter.secondValue,
            caseSensitive: filter.caseSensitive
        )
    }

    // MARK: - Placeholder check

    static let expressionKeys = [
        "KeyConditionExpression", "FilterExpression", "ProjectionExpression", "ConditionExpression", "UpdateExpression"
    ]

    static func placeholders(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "[#:][A-Za-z0-9_]+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        })
    }

    static func placeholderProblems(in request: [String: DynamoDBJSON]) -> [String] {
        let expressions = expressionKeys.compactMap { request[$0]?.stringValue }.joined(separator: " ")
        let referenced = placeholders(in: expressions)
        var declared: Set<String> = []
        var problems: [String] = []
        for (key, prefix) in [("ExpressionAttributeNames", "#"), ("ExpressionAttributeValues", ":")] {
            guard let entry = request[key] else { continue }
            guard let object = entry.objectValue else {
                problems.append("\(key) is not an object")
                continue
            }
            if object.isEmpty { problems.append("\(key) is empty") }
            for placeholder in object.keys.sorted() {
                declared.insert(placeholder)
                if !placeholder.hasPrefix(prefix) { problems.append("\(placeholder) is in \(key)") }
                if !referenced.contains(placeholder) { problems.append("\(placeholder) is declared but unused") }
            }
        }
        for placeholder in referenced.subtracting(declared).sorted() {
            problems.append("\(placeholder) is used but not declared")
        }
        return problems
    }

    static func placeholderProblems(in plan: DynamoDBReadPlan) -> [String] {
        plan.requests.flatMap { placeholderProblems(in: $0) }
    }

    @Test("The placeholder check flags unused, undeclared and empty placeholder maps")
    func placeholderCheckCanFail() {
        let request: [String: DynamoDBJSON] = [
            "FilterExpression": .string("#pk = :pk2 AND #sk > :sk"),
            "ExpressionAttributeNames": .object(["#pk": .string("pk")]),
            "ExpressionAttributeValues": .object([
                ":pk": .object(["S": .string("a")]),
                ":pk2": .object(["S": .string("b")]),
                ":sk": .object(["N": .string("1")])
            ])
        ]
        let empty: [String: DynamoDBJSON] = ["ExpressionAttributeNames": .object([:])]

        #expect(Self.placeholderProblems(in: request) == [":pk is declared but unused", "#sk is used but not declared"])
        #expect(Self.placeholderProblems(in: empty) == ["ExpressionAttributeNames is empty"])
    }

    // MARK: - Query on the table

    @Test("Equality on the partition key queries the table")
    func partitionEqualityQueriesTable() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x")])

        #expect(plan.access == .query)
        #expect(plan.indexName == nil)
        #expect(plan.requests.count == 1)
        let request = try #require(plan.requests.first)
        #expect(request["TableName"] == .string("orders"))
        #expect(Self.text("KeyConditionExpression", in: request) == "#pk = :pk")
        #expect(request["IndexName"] == nil)
        #expect(request["FilterExpression"] == nil)
        #expect(Self.names(in: request) == ["#pk": "pk"])
        #expect(try Self.values(in: request) == [":pk": .string("x")])
        #expect(plan.clientPredicates.isEmpty)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A range on the sort key joins the key condition")
    func sortRangeJoinsKeyCondition() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x"), Self.filter("sk", "BETWEEN", "1", second: "5")])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(Self.text("KeyConditionExpression", in: request) == "#pk = :pk AND #sk BETWEEN :sk AND :sk2")
        #expect(request["FilterExpression"] == nil)
        #expect(try Self.values(in: request) == [":pk": .string("x"), ":sk": .number("1"), ":sk2": .number("5")])
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A reversed range on the sort key reads nothing")
    func reversedSortRangeReadsNothing() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x"), Self.filter("sk", "BETWEEN", "9", second: "1")])

        #expect(plan.access == .nothing)
        #expect(plan.requests.isEmpty)
    }

    @Test("Descending order on the sort key reads the index backwards")
    func descendingSortKeyOrder() throws {
        let order = [DynamoDBOrderTerm(attribute: "sk", descending: true)]

        let plan = try Self.plan([Self.filter("pk", "=", "x")], order: order)

        let request = try #require(plan.requests.first)
        #expect(request["ScanIndexForward"] == .bool(false))
        #expect(plan.unsatisfiedOrder.isEmpty)
    }

    @Test("Ascending order on the sort key is the natural order")
    func ascendingSortKeyOrder() throws {
        let order = [DynamoDBOrderTerm(attribute: "sk", descending: false)]

        let plan = try Self.plan([Self.filter("pk", "=", "x")], order: order)

        let request = try #require(plan.requests.first)
        #expect(request["ScanIndexForward"] == nil)
        #expect(plan.unsatisfiedOrder.isEmpty)
    }

    @Test("Order on any other attribute is left to the reader")
    func otherOrderIsUnsatisfied() throws {
        let order = [DynamoDBOrderTerm(attribute: "customer", descending: true)]

        let plan = try Self.plan([Self.filter("pk", "=", "x")], order: order)

        let request = try #require(plan.requests.first)
        #expect(request["ScanIndexForward"] == nil)
        #expect(plan.unsatisfiedOrder == order)
    }

    @Test("A filter on a non-key attribute becomes the FilterExpression of the query")
    func nonKeyFilterOnQuery() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x"), Self.filter("customer", "=", "ann")])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(plan.indexName == nil)
        #expect(Self.text("KeyConditionExpression", in: request) == "#pk = :pk")
        #expect(Self.text("FilterExpression", in: request) == "#customer = :customer")
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A key attribute the key condition cannot use is checked on the client, never in a FilterExpression")
    func unusableKeyFilterGoesToClient() throws {
        let notEqual = Self.filter("sk", "!=", "3")

        let plan = try Self.plan([Self.filter("pk", "=", "x"), notEqual])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(Self.text("KeyConditionExpression", in: request) == "#pk = :pk")
        #expect(request["FilterExpression"] == nil)
        #expect(plan.clientPredicates == [Self.clientPredicate(notEqual)])
        #expect(plan.clientMatchAll)
        #expect(!plan.clientMatches(["pk": .string("x"), "sk": .number("3")]))
        #expect(plan.clientMatches(["pk": .string("x"), "sk": .number("4")]))
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    // MARK: - Indexes

    @Test("Equality on a global index partition key queries that index")
    func queriesGlobalIndex() throws {
        let plan = try Self.plan([Self.filter("status", "=", "shipped"), Self.filter("total", ">=", "100")])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(plan.indexName == "byStatus")
        #expect(request["IndexName"] == .string("byStatus"))
        #expect(request["Select"] == nil)
        #expect(Self.text("KeyConditionExpression", in: request) == "#status = :status AND #total >= :total")
        #expect(try Self.values(in: request) == [":status": .string("shipped"), ":total": .number("100")])
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A key attribute of the chosen index is checked on the client")
    func indexKeyFilterGoesToClient() throws {
        let notEqual = Self.filter("total", "!=", "5")

        let plan = try Self.plan([Self.filter("status", "=", "shipped"), notEqual])

        let request = try #require(plan.requests.first)
        #expect(plan.indexName == "byStatus")
        #expect(request["FilterExpression"] == nil)
        #expect(plan.clientPredicates == [Self.clientPredicate(notEqual)])
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test(
        "A global index is not used while an item missing its sort key could match",
        arguments: [
            [DynamoDBAccessPlannerTests.filter("status", "=", "shipped")],
            [DynamoDBAccessPlannerTests.filter("status", "=", "shipped"), DynamoDBAccessPlannerTests.filter("total", "IS NULL")]
        ]
    )
    func sparseGlobalIndexIsSkipped(_ filters: [DynamoDBBrowseFilter]) throws {
        let plan = try Self.plan(filters)

        let request = try #require(plan.requests.first)
        #expect(plan.access == .scan)
        #expect(plan.indexName == nil)
        #expect(request["IndexName"] == nil)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A local index is not used while an item missing its sort key could match")
    func sparseLocalIndexIsSkipped() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x"), Self.filter("created", "IS NULL")])

        #expect(plan.access == .query)
        #expect(plan.indexName == nil)
        #expect(plan.requests.first?["IndexName"] == nil)
    }

    @Test("A global index that does not project every attribute is not used")
    func keysOnlyGlobalIndexIsSkipped() throws {
        let plan = try Self.plan([Self.filter("zip", "=", "10001")])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .scan)
        #expect(plan.indexName == nil)
        #expect(request["IndexName"] == nil)
        #expect(request["KeyConditionExpression"] == nil)
        #expect(Self.text("FilterExpression", in: request) == "#zip = :zip")
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A local index with a sort filter is preferred and reads every attribute")
    func localIndexWithSortFilter() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x"), Self.filter("created", ">=", "2024")])

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(plan.indexName == "byCreated")
        #expect(request["IndexName"] == .string("byCreated"))
        #expect(request["Select"] == .string("ALL_ATTRIBUTES"))
        #expect(Self.text("KeyConditionExpression", in: request) == "#pk = :pk AND #created >= :created")
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("The table is preferred over a local index when no sort filter uses the index")
    func tablePreferredOverLocalIndex() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "x")])

        #expect(plan.indexName == nil)
        #expect(plan.requests.first?["IndexName"] == nil)
    }

    @Test("An index that is being built or backfilled is never chosen", arguments: [
        DynamoDBAccessPlannerTests.filter("email", "=", "a@example.com"),
        DynamoDBAccessPlannerTests.filter("phone", "=", "555")
    ])
    func unavailableIndexIsSkipped(_ filter: DynamoDBBrowseFilter) throws {
        let plan = try Self.plan([filter])

        #expect(plan.access == .scan)
        #expect(plan.indexName == nil)
        #expect(plan.requests.allSatisfy { $0["IndexName"] == nil })
    }

    // MARK: - Multi-attribute index keys

    @Test("A multi-attribute index is queried with every key attribute in the key condition")
    func multiAttributeIndexFullKey() throws {
        let plan = try Self.plan([
            Self.filter("tenant", "=", "t1"),
            Self.filter("region", "=", "eu"),
            Self.filter("year", "=", "2024"),
            Self.filter("month", ">", "3")
        ], on: Self.eventsDescription)

        let request = try #require(plan.requests.first)
        #expect(plan.access == .query)
        #expect(plan.indexName == "byTenantRegion")
        #expect(
            Self.text("KeyConditionExpression", in: request)
                == "#tenant = :tenant AND #region = :region AND #year = :year AND #month > :month"
        )
        #expect(try Self.values(in: request) == [
            ":tenant": .string("t1"), ":region": .string("eu"), ":year": .number("2024"), ":month": .number("3")
        ])
        #expect(plan.clientPredicates.isEmpty)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A multi-attribute index needs equality on every partition attribute", arguments: [
        [DynamoDBAccessPlannerTests.filter("tenant", "=", "t1")],
        [DynamoDBAccessPlannerTests.filter("tenant", "=", "t1"), DynamoDBAccessPlannerTests.filter("region", ">", "a")],
        [DynamoDBAccessPlannerTests.filter("tenant", "IN", "t1, t2"), DynamoDBAccessPlannerTests.filter("region", "=", "eu")]
    ])
    func multiAttributeIndexNeedsWholePartition(_ filters: [DynamoDBBrowseFilter]) throws {
        let plan = try Self.plan(filters, on: Self.eventsDescription)

        #expect(plan.access == .scan)
        #expect(plan.indexName == nil)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A range on the second sort attribute needs equality on the first")
    func multiAttributeSortNeedsLeadingEquality() throws {
        let hasYear = Self.filter("year", "IS NOT NULL")
        let month = Self.filter("month", ">", "3")

        let plan = try Self.plan([
            Self.filter("tenant", "=", "t1"),
            Self.filter("region", "=", "eu"),
            hasYear,
            month
        ], on: Self.eventsDescription)

        let request = try #require(plan.requests.first)
        #expect(plan.indexName == "byTenantRegion")
        #expect(Self.text("KeyConditionExpression", in: request) == "#tenant = :tenant AND #region = :region")
        #expect(request["FilterExpression"] == nil)
        #expect(plan.clientPredicates == [Self.clientPredicate(hasYear), Self.clientPredicate(month)])
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A multi-attribute index is not used while an item missing one of its sort attributes could match")
    func multiAttributeIndexNeedsEverySortAttribute() throws {
        let plan = try Self.plan([
            Self.filter("tenant", "=", "t1"),
            Self.filter("region", "=", "eu"),
            Self.filter("month", ">", "3")
        ], on: Self.eventsDescription)

        #expect(plan.access == .scan)
        #expect(plan.indexName == nil)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A range on the first sort attribute keeps the second out of the key condition")
    func multiAttributeRangeOnFirstSortAttribute() throws {
        let plan = try Self.plan([
            Self.filter("tenant", "=", "t1"),
            Self.filter("region", "=", "eu"),
            Self.filter("year", ">", "2020"),
            Self.filter("month", "=", "3")
        ], on: Self.eventsDescription)

        let request = try #require(plan.requests.first)
        let keyCondition = try #require(Self.text("KeyConditionExpression", in: request))
        #expect(plan.indexName == "byTenantRegion")
        #expect(keyCondition.hasPrefix("#tenant = :tenant AND #region = :region"))
        #expect(!keyCondition.contains("#month"))
        #expect(request["FilterExpression"] == nil)
        #expect(plan.clientPredicates.contains(Self.clientPredicate(Self.filter("month", "=", "3"))))
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    // MARK: - Partition lists

    @Test("An OR of partition keys on a table without a sort key reads the keys in one batch, in order")
    func orOfKeysWithoutSortKeyIsBatchGet() throws {
        let plan = try Self.plan(
            [Self.filter("pk", "=", "b"), Self.filter("pk", "=", "a"), Self.filter("pk", "=", "b")],
            matchAll: false,
            on: Self.sessionsDescription
        )

        #expect(plan.access == .batchGet)
        #expect(plan.requests == [[
            "RequestItems": .object(["sessions": .object([
                "Keys": .array([
                    .object(["pk": .object(["S": .string("b")])]),
                    .object(["pk": .object(["S": .string("a")])])
                ]),
                "ConsistentRead": .bool(true)
            ])])
        ]])
    }

    @Test("A batch of more than 100 keys is split into requests of at most 100")
    func batchGetChunks() throws {
        let filters = (0..<150).map { Self.filter("pk", "=", "k\($0)") }

        let plan = try Self.plan(filters, matchAll: false, on: Self.sessionsDescription)

        let counts = plan.requests.map { request in
            request["RequestItems"]?["sessions"]?["Keys"]?.arrayValue?.count ?? 0
        }
        #expect(plan.access == .batchGet)
        #expect(counts == [100, 50])
    }

    @Test("An OR of partition keys on a table with a sort key queries each partition")
    func orOfKeysWithSortKeyIsQueries() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "a"), Self.filter("pk", "=", "b")], matchAll: false)

        #expect(plan.access == .query)
        #expect(plan.indexName == nil)
        #expect(plan.requests.map { Self.text("KeyConditionExpression", in: $0) } == ["#pk = :pk", "#pk = :pk"])
        #expect(try plan.requests.map { try Self.values(in: $0) } == [[":pk": .string("a")], [":pk": .string("b")]])
        #expect(plan.requests.allSatisfy { $0["ConsistentRead"] == .bool(true) })
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("A page position belongs to the request it was read from, not only to the filters")
    func positionKeyNamesTheAccessPath() throws {
        let scan = try Self.plan([Self.filter("customer", "=", "ann")])
        let index = try Self.plan([Self.filter("status", "=", "shipped"), Self.filter("total", ">", "1")])
        let table = try Self.plan([Self.filter("pk", "=", "a")])

        #expect(Set([scan.positionKey, index.positionKey, table.positionKey]).count == 3)
    }

    @Test("In on the partition key with another filter queries each partition with that filter")
    func partitionInWithFilter() throws {
        let plan = try Self.plan([Self.filter("pk", "IN", "a, b"), Self.filter("customer", "=", "ann")])

        #expect(plan.access == .query)
        #expect(plan.requests.count == 2)
        #expect(plan.requests.map { Self.text("KeyConditionExpression", in: $0) } == ["#pk = :pk", "#pk = :pk"])
        #expect(plan.requests.map { Self.text("FilterExpression", in: $0) } == ["#customer = :customer", "#customer = :customer"])
        #expect(try plan.requests.map { try Self.values(in: $0) } == [
            [":pk": .string("a"), ":customer": .string("ann")],
            [":pk": .string("b"), ":customer": .string("ann")]
        ])
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("In on the partition key queries each distinct partition once")
    func partitionInDeduplicates() throws {
        let plan = try Self.plan([Self.filter("pk", "IN", "a, a, b")])

        #expect(plan.access == .query)
        #expect(try plan.requests.map { try Self.values(in: $0) } == [[":pk": .string("a")], [":pk": .string("b")]])
    }

    @Test("Order on the sort key across several partitions is left to the reader")
    func partitionInOrderIsUnsatisfied() throws {
        let order = [DynamoDBOrderTerm(attribute: "sk", descending: true)]

        let plan = try Self.plan([Self.filter("pk", "IN", "a, b")], order: order)

        #expect(plan.requests.count == 2)
        #expect(plan.unsatisfiedOrder == order)
    }

    // MARK: - Match any

    @Test("An OR with a non-key filter scans with an OR FilterExpression")
    func orWithNonKeyFilterScans() throws {
        let plan = try Self.plan([Self.filter("pk", "=", "a"), Self.filter("customer", "=", "ann")], matchAll: false)

        let request = try #require(plan.requests.first)
        #expect(plan.access == .scan)
        #expect(Self.text("FilterExpression", in: request) == "#pk = :pk OR #customer = :customer")
        #expect(plan.clientPredicates.isEmpty)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    @Test("An OR where one filter needs the client checks every filter on the client")
    func orWithClientFilter() throws {
        let key = Self.filter("pk", "=", "a")
        let suffix = Self.filter("customer", "ENDS WITH", "nn")

        let plan = try Self.plan([key, suffix], matchAll: false)

        #expect(plan.access == .scan)
        #expect(plan.requests == [["TableName": .string("orders")]])
        #expect(plan.clientPredicates == [Self.clientPredicate(key), Self.clientPredicate(suffix)])
        #expect(!plan.clientMatchAll)
        #expect(plan.clientMatches(["pk": .string("a"), "customer": .string("bob")]))
        #expect(plan.clientMatches(["pk": .string("b"), "customer": .string("ann")]))
        #expect(!plan.clientMatches(["pk": .string("b"), "customer": .string("bob")]))
    }

    @Test("An OR term that can match nothing leaves no placeholder behind")
    func orDropsImpossibleTermCleanly() throws {
        let plan = try Self.plan([Self.filter("customer", "=", "ann"), Self.filter("sk", "=", "abc")], matchAll: false)

        let request = try #require(plan.requests.first)
        #expect(plan.access == .scan)
        #expect(Self.text("FilterExpression", in: request) == "#customer = :customer")
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }

    // MARK: - Impossible and refused filters

    @Test("A Number key compared with text that is not a number reads nothing", arguments: [
        DynamoDBAccessPlannerTests.filter("sk", "=", "abc"),
        DynamoDBAccessPlannerTests.filter("total", "=", "abc")
    ])
    func numberKeyWithTextReadsNothing(_ filter: DynamoDBBrowseFilter) throws {
        let plan = try Self.plan([filter])

        #expect(plan.access == .nothing)
        #expect(plan.requests.isEmpty)
    }

    @Test("A raw filter is refused")
    func rawFilterThrows() throws {
        let raw = Self.filter(DynamoDBFilterTranslator.rawFilterColumn, "=", "a = 1")
        let reason = try #require(DynamoDBFilterTranslator.unsupportedReason(for: raw))

        #expect(throws: DynamoDBError.invalidStatement(reason)) {
            try Self.plan([Self.filter("pk", "=", "x"), raw])
        }
    }

    // MARK: - Placeholders

    static let scenarios: [Scenario] = [
        Scenario("table query with mixed filters", [
            filter("pk", "=", "x"), filter("sk", ">", "3"), filter("customer", "CONTAINS", "a"),
            filter("total", "IS NULL"), filter("note", "IS NOT EMPTY")
        ]),
        Scenario("index query with filters", [
            filter("status", "=", "s"), filter("customer", "NOT IN", "a, b"), filter("flag", "=", "true")
        ]),
        Scenario("local index query with filters", [
            filter("pk", "=", "x"), filter("created", "BETWEEN", "a", second: "b"), filter("customer", "!=", "z")
        ]),
        Scenario("scan with typed readings", [
            filter("customer", "=", "5"), filter("flag", "=", "true"), filter("note", "BETWEEN", "1,9")
        ]),
        Scenario("per-partition queries", [filter("pk", "IN", "a, b"), filter("customer", "BETWEEN", "1", second: "9")]),
        Scenario("match any scan", [
            filter("customer", "=", "5"), filter("note", "STARTS WITH", "x"), filter("total", ">", "3")
        ], matchAll: false),
        Scenario("nested paths", [filter("address.city", "=", "Hanoi"), filter("items[0].sku", "IN", "A1, B2")]),
        Scenario(
            "names that need placeholders",
            [filter("order-id", "=", "1"), filter("a.b", "=", "2"), filter("name", "IS NOT NULL")],
            columns: ["a.b"]
        ),
        Scenario("client filter beside a server filter", [filter("customer", "=", "ann"), filter("note", "ENDS WITH", "z")]),
        Scenario("descending sort key", [filter("pk", "=", "x")], order: [DynamoDBOrderTerm(attribute: "sk", descending: true)])
    ]

    @Test("No request declares a placeholder its expressions do not use", arguments: scenarios)
    func everyPlaceholderIsUsed(_ scenario: Scenario) throws {
        let plan = try Self.plan(scenario.filters, matchAll: scenario.matchAll, order: scenario.order, columns: scenario.columns)

        #expect(plan.access != .nothing)
        #expect(Self.placeholderProblems(in: plan).isEmpty)
    }
}
