//
//  EtcdQueryBuilderTests.swift
//  TableProTests
//
//  Tests for EtcdQueryBuilder (compiled via symlink from EtcdDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

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
        #expect(parsed?.filter == .unfiltered)
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

struct EtcdQueryBuilderFilteredTests {
    private let builder = EtcdQueryBuilder()

    private func conditions(
        _ filters: [PluginQueryFilter],
        logicMode: String = "and"
    ) -> [(column: EtcdColumn, comparison: EtcdComparison, value: String)]? {
        let query = builder.buildFilteredQuery(
            prefix: "", filters: filters, logicMode: logicMode, sortColumns: [], limit: 100, offset: 0
        )
        return EtcdQueryBuilder.parseRangeQuery(query)?.filter.conditions.map {
            (column: $0.column, comparison: $0.comparison, value: $0.value)
        }
    }

    private func refusal(_ filters: [PluginQueryFilter]) -> String? {
        let query = builder.buildFilteredQuery(
            prefix: "", filters: filters, logicMode: "and", sortColumns: [], limit: 100, offset: 0
        )
        return EtcdQueryBuilder.parseRefusal(query)?.pluginErrorMessage
    }

    @Test("Key equals filter")
    func keyEqualsFilter() throws {
        let carried = try #require(conditions([PluginQueryFilter(column: "Key", op: "=", value: "/app/config")]))
        #expect(carried.map(\.comparison) == [.equal])
        #expect(carried.map(\.value) == ["/app/config"])
    }

    @Test("Key contains, starts-with and ends-with filters")
    func keyPatternFilters() {
        let cases: [(op: String, comparison: EtcdComparison)] = [
            ("CONTAINS", .contains), ("STARTS WITH", .startsWith), ("ENDS WITH", .endsWith),
        ]
        for (op, comparison) in cases {
            let carried = conditions([PluginQueryFilter(column: "Key", op: op, value: "cfg")])
            #expect(carried?.map(\.comparison) == [comparison], "\(op)")
        }
    }

    @Test("A Value filter builds a range query the driver runs")
    func valueFilterBuildsRange() throws {
        let carried = try #require(conditions([PluginQueryFilter(column: "Value", op: "CONTAINS", value: "test")]))
        #expect(carried.map(\.column) == [.value])
    }

    @Test("A Lease filter is carried to the driver")
    func leaseFilterIsCarried() throws {
        let carried = try #require(conditions([PluginQueryFilter(column: "Lease", op: "=", value: "0x7b")]))
        #expect(carried.map(\.column) == [.lease])
    }

    @Test("Key and Value filters are both carried")
    func mixedKeyAndValueFilters() throws {
        let carried = try #require(conditions([
            PluginQueryFilter(column: "Key", op: "CONTAINS", value: "test"),
            PluginQueryFilter(column: "Value", op: "CONTAINS", value: "data"),
        ]))
        #expect(carried.map(\.column) == [.key, .value])
    }

    @Test("Key NOT CONTAINS is carried rather than dropped")
    func keyNotContainsIsCarried() throws {
        let carried = try #require(conditions([PluginQueryFilter(column: "Key", op: "NOT CONTAINS", value: "x")]))
        #expect(carried.map(\.comparison) == [.notContains])
    }

    @Test("Two Key filters in OR mode are both carried and either may match")
    func keyFiltersInOrMode() throws {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [
                PluginQueryFilter(column: "Key", op: "=", value: "/a"),
                PluginQueryFilter(column: "Key", op: "=", value: "/b"),
            ],
            logicMode: "or",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        let filter = try #require(EtcdQueryBuilder.parseRangeQuery(query)?.filter)
        #expect(filter.conditions.map(\.value) == ["/a", "/b"])
        #expect(filter.matchesAll == false)
    }

    @Test("A filter etcd cannot evaluate becomes a refusal, never an unfiltered range")
    func unsupportedFilterIsRefused() {
        let query = builder.buildFilteredQuery(
            prefix: "",
            filters: [PluginQueryFilter(column: "__RAW__", op: "=", value: "a = 1")],
            logicMode: "and",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        #expect(EtcdQueryBuilder.isTaggedQuery(query))
        #expect(EtcdQueryBuilder.parseRangeQuery(query) == nil)
        #expect(refusal([PluginQueryFilter(column: "__RAW__", op: "=", value: "a = 1")])
            == "etcd cannot filter with a raw SQL condition.")
        #expect(refusal([PluginQueryFilter(column: "Key", op: "SOUNDS LIKE", value: "x")])
            == "etcd cannot filter with SOUNDS LIKE.")
    }
}

struct EtcdQueryBuilderCountTests {
    private let builder = EtcdQueryBuilder()

    @Test("Count query round-trip")
    func countQueryRoundTrip() {
        let query = builder.buildCountQuery(prefix: "/myprefix/")
        #expect(EtcdQueryBuilder.isTaggedQuery(query))
        let parsed = EtcdQueryBuilder.parseCountQuery(query)
        #expect(parsed != nil)
        #expect(parsed?.prefix == "/myprefix/")
    }

    @Test("Count query with empty prefix")
    func countQueryEmptyPrefix() {
        let query = builder.buildCountQuery(prefix: "")
        let parsed = EtcdQueryBuilder.parseCountQuery(query)
        #expect(parsed?.prefix == "")
    }
}

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
        #expect(parsed?.filter == .unfiltered)
    }

    @Test("Prefix containing colon round-trips correctly")
    func prefixWithColon() {
        let builder = EtcdQueryBuilder()
        let query = builder.buildBrowseQuery(prefix: "ns:key:", sortColumns: [], limit: 10, offset: 0)
        let parsed = EtcdQueryBuilder.parseRangeQuery(query)
        #expect(parsed?.prefix == "ns:key:")
    }
}
