//
//  EtcdQueryBuilderTests.swift
//  TableProTests
//
//  Tests for EtcdQueryBuilder (compiled via symlink from EtcdDriverPlugin).
//

import Foundation
import Testing

@Suite("EtcdQueryBuilder - Browse Query")
struct EtcdQueryBuilderBrowseTests {
    private let builder = EtcdQueryBuilder()

    @Test("Empty prefix produces valid range query")
    func emptyPrefix() {
        let query = builder.buildBrowseQuery(prefix: "", sortColumns: [], limit: 100, offset: 0)
        #expect(EtcdQueryBuilder.isTaggedQuery(query))
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.prefix == "")
        #expect(parsed?.limit == 100)
        #expect(parsed?.offset == 0)
        #expect(parsed?.sortAscending == true)
        #expect(parsed?.filterType == .none)
        #expect(parsed?.filterValue == "")
    }

    @Test("Non-empty prefix is encoded and decoded correctly")
    func withPrefix() {
        let query = builder.buildBrowseQuery(prefix: "/app/config/", sortColumns: [], limit: 50, offset: 10)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.prefix == "/app/config/")
        #expect(parsed?.limit == 50)
        #expect(parsed?.offset == 10)
    }

    @Test("Sort ascending from sortColumns")
    func sortAscending() {
        let query = builder.buildBrowseQuery(
            prefix: "",
            sortColumns: [(columnIndex: 0, ascending: true)],
            limit: 100,
            offset: 0
        )
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.sortAscending == true)
    }

    @Test("Sort descending from sortColumns")
    func sortDescending() {
        let query = builder.buildBrowseQuery(
            prefix: "",
            sortColumns: [(columnIndex: 0, ascending: false)],
            limit: 100,
            offset: 0
        )
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.sortAscending == false)
    }

    @Test("Different limit and offset values")
    func differentLimitOffset() {
        let query = builder.buildBrowseQuery(prefix: "test/", sortColumns: [], limit: 500, offset: 250)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.limit == 500)
        #expect(parsed?.offset == 250)
    }
}

@Suite("EtcdQueryBuilder - Filtered Query")
struct EtcdQueryBuilderFilteredTests {
    private let builder = EtcdQueryBuilder()

    @Test("Key equals filter")
    func keyEqualsFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Key", op: "=", value: "/app/config")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .equals)
        #expect(parsed?.filterValue == "/app/config")
    }

    @Test("Key contains filter")
    func keyContainsFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Key", op: "CONTAINS", value: "config")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .contains)
        #expect(parsed?.filterValue == "config")
    }

    @Test("Key starts-with filter")
    func keyStartsWithFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Key", op: "STARTS WITH", value: "/app")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .startsWith)
        #expect(parsed?.filterValue == "/app")
    }

    @Test("Key ends-with filter")
    func keyEndsWithFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Key", op: "ENDS WITH", value: ".json")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .endsWith)
        #expect(parsed?.filterValue == ".json")
    }

    @Test("Unsupported filter on Value column returns nil")
    func unsupportedValueFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Value", op: "CONTAINS", value: "test")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query == nil)
    }

    @Test("Unsupported filter on Lease column returns nil")
    func unsupportedLeaseFilter() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Lease", op: "=", value: "123")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query == nil)
    }

    @Test("Mixed Key and Value filters returns nil")
    func mixedKeyAndValueFilters() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [
                (column: "Key", op: "CONTAINS", value: "test"),
                (column: "Value", op: "CONTAINS", value: "data")
            ],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query == nil)
    }

    @Test("Unknown op falls back to none filter type")
    func unknownFilterOp() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [(column: "Key", op: "REGEX", value: ".*")],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .none)
    }
}

@Suite("EtcdQueryBuilder - Combined Query")
struct EtcdQueryBuilderCombinedTests {
    private let builder = EtcdQueryBuilder()

    @Test("Combined with search text takes precedence over filters")
    func searchTextTakesPrecedence() {
        let query = builder.buildCombinedQuery(
            prefix: "",
            filters: [(column: "Key", op: "=", value: "exact")],
            logicMode: "AND",
            searchText: "search",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .contains)
        #expect(parsed?.filterValue == "search")
    }

    @Test("Combined with empty search text falls back to filters")
    func emptySearchFallsBackToFilters() {
        let query = builder.buildCombinedQuery(
            prefix: "",
            filters: [(column: "Key", op: "=", value: "exact")],
            logicMode: "AND",
            searchText: "",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query != nil)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query!)
        #expect(parsed?.filterType == .equals)
        #expect(parsed?.filterValue == "exact")
    }

    @Test("Combined with unsupported filter returns nil")
    func combinedUnsupportedFilter() {
        let query = builder.buildCombinedQuery(
            prefix: "",
            filters: [(column: "Value", op: "CONTAINS", value: "test")],
            logicMode: "AND",
            searchText: "",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(query == nil)
    }
}

@Suite("EtcdQueryBuilder - Count Query")
struct EtcdQueryBuilderCountTests {
    private let builder = EtcdQueryBuilder()

    @Test("Count query round-trip")
    func countQueryRoundTrip() {
        let query = builder.buildCountQuery(prefix: "/myprefix/")
        #expect(EtcdQueryBuilder.isTaggedQuery(query))
        let parsed = EtcdQueryBuilder.parseCountQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.prefix == "/myprefix/")
        #expect(parsed?.filterType == .none)
        #expect(parsed?.filterValue == "")
    }

    @Test("Count query with empty prefix")
    func countQueryEmptyPrefix() {
        let query = builder.buildCountQuery(prefix: "")
        let parsed = EtcdQueryBuilder.parseCountQuery(query)
        #expect(parsed?.prefix == "")
    }
}

@Suite("EtcdQueryBuilder - Tag Detection and Parsing")
struct EtcdQueryBuilderTagTests {
    @Test("isTaggedQuery detects range tag")
    func detectsRangeTag() {
        #expect(EtcdQueryBuilder.isTaggedQuery("ETCD_RANGE:abc"))
        #expect(!EtcdQueryBuilder.isTaggedQuery("get key"))
    }

    @Test("isTaggedQuery detects count tag")
    func detectsCountTag() {
        #expect(EtcdQueryBuilder.isTaggedQuery("ETCD_COUNT:abc"))
        #expect(!EtcdQueryBuilder.isTaggedQuery("put key value"))
    }

    @Test("parseRangeQuery returns nil for non-range query")
    func parseRangeNonTagged() {
        #expect(EtcdQueryBuilder.parseRangeQuery("get key") == nil)
    }

    @Test("parseCountQuery returns nil for non-count query")
    func parseCountNonTagged() {
        #expect(EtcdQueryBuilder.parseCountQuery("get key") == nil)
    }

    @Test("parseRangeQuery returns nil for malformed body")
    func parseRangeMalformed() {
        #expect(EtcdQueryBuilder.parseRangeQuery("ETCD_RANGE:bad") == nil)
    }

    @Test("parseCountQuery returns nil for malformed body")
    func parseCountMalformed() {
        #expect(EtcdQueryBuilder.parseCountQuery("ETCD_COUNT:bad") == nil)
    }

    @Test("Range query encode/parse round-trip preserves all fields")
    func rangeRoundTrip() {
        let builder = EtcdQueryBuilder()
        let query = builder.buildBrowseQuery(
            prefix: "my/prefix/",
            sortColumns: [(columnIndex: 0, ascending: false)],
            limit: 42,
            offset: 7
        )
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.prefix == "my/prefix/")
        #expect(parsed?.limit == 42)
        #expect(parsed?.offset == 7)
        #expect(parsed?.sortAscending == false)
        #expect(parsed?.filterType == .none)
        #expect(parsed?.filterValue == "")
    }

    @Test("Prefix containing colon round-trips correctly")
    func prefixWithColon() {
        let builder = EtcdQueryBuilder()
        let query = builder.buildBrowseQuery(prefix: "ns:key:", sortColumns: [], limit: 10, offset: 0)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.prefix == "ns:key:")
    }
}
