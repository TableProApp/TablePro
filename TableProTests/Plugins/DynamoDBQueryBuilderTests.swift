//
//  DynamoDBQueryBuilderTests.swift
//  TableProTests
//
//  Tests for DynamoDBQueryBuilder (compiled via symlink from DynamoDBDriverPlugin).
//

import Foundation
import Testing

@Suite("DynamoDBQueryBuilder - Browse Query")
struct DynamoDBQueryBuilderBrowseTests {
    private let builder = DynamoDBQueryBuilder()

    @Test("Browse query returns scan-tagged string")
    func browseReturnsScanTag() {
        let query = builder.buildBrowseQuery(table: "Users", sortColumns: [], limit: 100, offset: 0)
        #expect(query.hasPrefix(DynamoDBQueryBuilder.scanTag))
    }

    @Test("Browse query round-trips through parseScanQuery")
    func browseRoundTrip() {
        let query = builder.buildBrowseQuery(table: "Users", sortColumns: [], limit: 50, offset: 10)
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.tableName == "Users")
        #expect(parsed?.limit == 50)
        #expect(parsed?.offset == 10)
        #expect(parsed?.filters.isEmpty == true)
    }
}

@Suite("DynamoDBQueryBuilder - Filtered Query")
struct DynamoDBQueryBuilderFilteredTests {
    private let builder = DynamoDBQueryBuilder()

    @Test("Without PK filter returns scan-tagged")
    func nonPkFilterReturnsScan() {
        let query = builder.buildFilteredQuery(
            table: "Users",
            filters: [(column: "name", op: "=", value: "Alice")],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id", "name"],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        #expect(query!.hasPrefix(DynamoDBQueryBuilder.scanTag))
    }

    @Test("With PK equals filter returns query-tagged")
    func pkFilterReturnsQuery() {
        let query = builder.buildFilteredQuery(
            table: "Users",
            filters: [(column: "id", op: "=", value: "pk1")],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id", "name"],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        #expect(query!.hasPrefix(DynamoDBQueryBuilder.queryTag))
    }

    @Test("PK filter with additional filters returns query-tagged with remaining filters")
    func pkPlusAdditionalFilters() {
        let query = builder.buildFilteredQuery(
            table: "Users",
            filters: [
                (column: "id", op: "=", value: "pk1"),
                (column: "name", op: "CONTAINS", value: "Al")
            ],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id", "name"],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        #expect(query!.hasPrefix(DynamoDBQueryBuilder.queryTag))
        let parsed = DynamoDBQueryBuilder.parseQueryQuery(query!)
        #expect(parsed != nil)
        #expect(parsed?.partitionKeyValue == "pk1")
        #expect(parsed?.filters.count == 1)
        #expect(parsed?.filters.first?.column == "name")
    }

    @Test("Multiple non-key filters returns scan-tagged with all filters")
    func multipleNonKeyFilters() {
        let query = builder.buildFilteredQuery(
            table: "Users",
            filters: [
                (column: "name", op: "=", value: "Alice"),
                (column: "age", op: ">", value: "25")
            ],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id", "name", "age"],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        #expect(query!.hasPrefix(DynamoDBQueryBuilder.scanTag))
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query!)
        #expect(parsed?.filters.count == 2)
    }
}

@Suite("DynamoDBQueryBuilder - Combined Query")
struct DynamoDBQueryBuilderCombinedTests {
    private let builder = DynamoDBQueryBuilder()

    @Test("Filters only produces filtered query")
    func filtersOnly() {
        let query = builder.buildCombinedQuery(
            table: "Users",
            filters: [(column: "name", op: "=", value: "Alice")],
            logicMode: "AND",
            searchText: "",
            sortColumns: [],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        #expect(query!.hasPrefix(DynamoDBQueryBuilder.scanTag))
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query!)
        #expect(parsed?.filters.count == 1)
    }

    @Test("Search only produces scan with CONTAINS")
    func searchOnly() {
        let query = builder.buildCombinedQuery(
            table: "Users",
            filters: [],
            logicMode: "AND",
            searchText: "test",
            sortColumns: [],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query!)
        #expect(parsed?.filters.count == 1)
        #expect(parsed?.filters.first?.column == "*")
        #expect(parsed?.filters.first?.op == "CONTAINS")
    }

    @Test("Both filters and search are merged")
    func filtersAndSearch() {
        let query = builder.buildCombinedQuery(
            table: "Users",
            filters: [(column: "name", op: "=", value: "Alice")],
            logicMode: "AND",
            searchText: "test",
            sortColumns: [],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query!)
        #expect(parsed?.filters.count == 2)
    }

    @Test("Empty filters and empty search produces plain scan")
    func emptyBoth() {
        let query = builder.buildCombinedQuery(
            table: "Users",
            filters: [],
            logicMode: "AND",
            searchText: "",
            sortColumns: [],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query!)
        #expect(parsed?.filters.isEmpty == true)
    }
}

@Suite("DynamoDBQueryBuilder - Parse Scan Query")
struct DynamoDBQueryBuilderParseScanTests {
    @Test("Valid scan string parses correctly")
    func validScanParse() {
        let builder = DynamoDBQueryBuilder()
        let query = builder.buildBrowseQuery(table: "MyTable", sortColumns: [], limit: 200, offset: 50)
        let parsed = DynamoDBQueryBuilder.parseScanQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.tableName == "MyTable")
        #expect(parsed?.limit == 200)
        #expect(parsed?.offset == 50)
        #expect(parsed?.logicMode == "AND")
    }

    @Test("Invalid prefix returns nil")
    func invalidPrefix() {
        let parsed = DynamoDBQueryBuilder.parseScanQuery("SELECT * FROM users")
        #expect(parsed == nil)
    }

    @Test("Too few parts returns nil")
    func tooFewParts() {
        let parsed = DynamoDBQueryBuilder.parseScanQuery("DYNAMODB_SCAN:abc:123")
        #expect(parsed == nil)
    }
}

@Suite("DynamoDBQueryBuilder - Parse Query Query")
struct DynamoDBQueryBuilderParseQueryTests {
    @Test("Valid query string parses correctly")
    func validQueryParse() {
        let builder = DynamoDBQueryBuilder()
        let query = builder.buildFilteredQuery(
            table: "Users",
            filters: [(column: "id", op: "=", value: "pk1")],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id", "name"],
            limit: 100,
            offset: 0,
            keySchema: [("id", "HASH")]
        )

        #expect(query != nil)
        let parsed = DynamoDBQueryBuilder.parseQueryQuery(query!)
        #expect(parsed != nil)
        #expect(parsed?.tableName == "Users")
        #expect(parsed?.partitionKeyName == "id")
        #expect(parsed?.partitionKeyValue == "pk1")
        #expect(parsed?.partitionKeyType == "S")
        #expect(parsed?.limit == 100)
        #expect(parsed?.offset == 0)
    }

    @Test("Too few parts returns nil")
    func tooFewParts() {
        let parsed = DynamoDBQueryBuilder.parseQueryQuery("DYNAMODB_QUERY:abc:123:456")
        #expect(parsed == nil)
    }
}

@Suite("DynamoDBQueryBuilder - Parse Count Query")
struct DynamoDBQueryBuilderParseCountTests {
    @Test("Basic count query parses correctly")
    func basicCount() {
        let query = DynamoDBQueryBuilder.encodeCountQuery(tableName: "Users")
        let parsed = DynamoDBQueryBuilder.parseCountQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.tableName == "Users")
        #expect(parsed?.filterColumn == nil)
        #expect(parsed?.filterOp == nil)
        #expect(parsed?.filterValue == nil)
    }

    @Test("Count with filter parses correctly")
    func countWithFilter() {
        let query = DynamoDBQueryBuilder.encodeCountQuery(
            tableName: "Users",
            filterColumn: "status",
            filterOp: "=",
            filterValue: "active"
        )
        let parsed = DynamoDBQueryBuilder.parseCountQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.tableName == "Users")
        #expect(parsed?.filterColumn == "status")
        #expect(parsed?.filterOp == "=")
        #expect(parsed?.filterValue == "active")
    }

    @Test("Wrong prefix returns nil")
    func wrongPrefix() {
        let parsed = DynamoDBQueryBuilder.parseCountQuery("DYNAMODB_SCAN:abc:100:0:W10=:QU5E")
        #expect(parsed == nil)
    }
}

@Suite("DynamoDBQueryBuilder - isTaggedQuery")
struct DynamoDBQueryBuilderIsTaggedTests {
    @Test("Scan-tagged string returns true")
    func scanTagged() {
        let builder = DynamoDBQueryBuilder()
        let query = builder.buildBrowseQuery(table: "T", sortColumns: [], limit: 10, offset: 0)
        #expect(DynamoDBQueryBuilder.isTaggedQuery(query))
    }

    @Test("Query-tagged string returns true")
    func queryTagged() {
        let builder = DynamoDBQueryBuilder()
        let query = builder.buildFilteredQuery(
            table: "T",
            filters: [(column: "id", op: "=", value: "x")],
            logicMode: "AND",
            sortColumns: [],
            columns: ["id"],
            limit: 10,
            offset: 0,
            keySchema: [("id", "HASH")]
        )
        #expect(query != nil)
        #expect(DynamoDBQueryBuilder.isTaggedQuery(query!))
    }

    @Test("Count-tagged string returns true")
    func countTagged() {
        let query = DynamoDBQueryBuilder.encodeCountQuery(tableName: "T")
        #expect(DynamoDBQueryBuilder.isTaggedQuery(query))
    }

    @Test("Regular SQL returns false")
    func regularSql() {
        #expect(!DynamoDBQueryBuilder.isTaggedQuery("SELECT * FROM users"))
    }
}
