//
//  DuckDBFileKindsTests.swift
//  TableProTests
//
//  Tests for DuckDBFileKinds (compiled via project.yml from DuckDBDriverPlugin).
//

import Foundation
import Testing

@Suite("DuckDB file kinds")
struct DuckDBFileKindsTests {
    @Test("The database formats lead, so the file field's placeholder names one")
    func databaseFormatsComeFirst() {
        #expect(DuckDBFileKinds.all.first == "duckdb")
        #expect(DuckDBFileKinds.all.prefix(2) == ["duckdb", "ddb"])
    }

    @Test("Every kind DuckDB can open is offered, with no duplicates")
    func allCoversBothGroups() {
        #expect(DuckDBFileKinds.all == DuckDBFileKinds.database + DuckDBFileKinds.readOnlyData)
        #expect(Set(DuckDBFileKinds.all).count == DuckDBFileKinds.all.count)
        for kind in ["parquet", "csv", "tsv", "json"] {
            #expect(DuckDBFileKinds.all.contains(kind))
        }
    }

    @Test("A missing database path may be created, because that is how you make a new one")
    func databasePathsCanBeCreated() {
        #expect(DuckDBFileKinds.canBeCreated(atPath: "/tmp/new.duckdb"))
        #expect(DuckDBFileKinds.canBeCreated(atPath: "/tmp/new.ddb"))
        #expect(DuckDBFileKinds.canBeCreated(atPath: "/tmp/new"))
        #expect(DuckDBFileKinds.canBeCreated(atPath: ":memory:"))
    }

    @Test("A missing data-file path is a typo, not a request to create an empty database")
    func dataFilePathsAreNotCreated() {
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/sales.parquet"))
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/sales.csv"))
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/sales.tsv"))
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/sales.json"))
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/sales.ndjson"))
    }

    @Test("The extension check ignores case")
    func extensionMatchIgnoresCase() {
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/Sales.PARQUET"))
        #expect(!DuckDBFileKinds.canBeCreated(atPath: "/tmp/Sales.Csv"))
    }
}
