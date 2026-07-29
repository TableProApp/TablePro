//
//  ClickHouseTableOperationsTests.swift
//  TableProTests
//

import Testing

@Suite("ClickHouse Table Operations")
struct ClickHouseTableOperationsTests {
    @Test("MergeTree engine classifies as TABLE")
    func mergeTreeIsTable() {
        #expect(clickHouseTableType(forEngine: "MergeTree") == "TABLE")
    }

    @Test("View engine classifies as VIEW")
    func viewIsView() {
        #expect(clickHouseTableType(forEngine: "View") == "VIEW")
    }

    @Test("MaterializedView engine classifies as MATERIALIZED VIEW")
    func materializedViewIsDistinctFromView() {
        #expect(clickHouseTableType(forEngine: "MaterializedView") == "MATERIALIZED VIEW")
    }

    @Test("LiveView and WindowView engines classify as VIEW")
    func experimentalViewEnginesAreViews() {
        #expect(clickHouseTableType(forEngine: "LiveView") == "VIEW")
        #expect(clickHouseTableType(forEngine: "WindowView") == "VIEW")
    }

    @Test("Nil engine classifies as TABLE")
    func nilEngineIsTable() {
        #expect(clickHouseTableType(forEngine: nil) == "TABLE")
    }

    @Test("Materialized view drops via DROP VIEW")
    func dropMaterializedViewUsesViewKeyword() {
        let stmt = clickHouseDropObjectStatement(name: "daily_sales", objectType: "MATERIALIZED VIEW")
        #expect(stmt == "DROP VIEW `daily_sales`")
    }

    @Test("Backticks in the name are escaped")
    func escapesBackticks() {
        let stmt = clickHouseDropObjectStatement(name: "weird`name", objectType: "MATERIALIZED VIEW")
        #expect(stmt == "DROP VIEW `weird``name`")
    }

    @Test("Other object types fall through to the default statement")
    func otherTypesReturnNil() {
        #expect(clickHouseDropObjectStatement(name: "orders", objectType: "TABLE") == nil)
        #expect(clickHouseDropObjectStatement(name: "active_users", objectType: "VIEW") == nil)
    }
}
