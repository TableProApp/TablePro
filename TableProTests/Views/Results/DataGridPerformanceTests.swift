//
//  DataGridPerformanceTests.swift
//  TableProTests
//
//  Tests for sort key pre-extraction performance optimization.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Sort Key Caching")
struct SortKeyCachingTests {
    @Test("Pre-extracted sort keys match inline comparison")
    func preExtractedKeysMatchInline() {
        let rows = TestFixtures.makeQueryResultRows(count: 5, columns: ["name", "age"])

        let sortColumnIndex = 0
        let keys: [String] = rows.map { row in
            sortColumnIndex < row.values.count ? (row.values[sortColumnIndex] ?? "") : ""
        }

        var indices1 = Array(0..<rows.count)
        indices1.sort { keys[$0].localizedStandardCompare(keys[$1]) == .orderedAscending }

        var indices2 = Array(0..<rows.count)
        indices2.sort {
            let v1 = sortColumnIndex < rows[$0].values.count ? (rows[$0].values[sortColumnIndex] ?? "") : ""
            let v2 = sortColumnIndex < rows[$1].values.count ? (rows[$1].values[sortColumnIndex] ?? "") : ""
            return v1.localizedStandardCompare(v2) == .orderedAscending
        }

        #expect(indices1 == indices2)
    }

    @Test("Sort with multiple columns and mixed directions")
    func multiColumnMixedDirections() {
        let rows = [
            QueryResultRow(id: 0, values: ["Alice", "30"]),
            QueryResultRow(id: 1, values: ["Bob", "25"]),
            QueryResultRow(id: 2, values: ["Alice", "20"]),
            QueryResultRow(id: 3, values: ["Bob", "35"]),
        ]

        let sortKeys: [[String]] = rows.map { row in
            [row.values[0] ?? "", row.values[1] ?? ""]
        }

        var indices = Array(0..<rows.count)
        indices.sort { i1, i2 in
            let result = sortKeys[i1][0].localizedStandardCompare(sortKeys[i2][0])
            if result != .orderedSame {
                return result == .orderedAscending
            }
            let result2 = sortKeys[i1][1].localizedStandardCompare(sortKeys[i2][1])
            return result2 == .orderedDescending
        }

        // Alice should come first, with age 30 before 20 (descending)
        #expect(rows[indices[0]].values[0] == "Alice")
        #expect(rows[indices[0]].values[1] == "30")
        #expect(rows[indices[1]].values[0] == "Alice")
        #expect(rows[indices[1]].values[1] == "20")
        #expect(rows[indices[2]].values[0] == "Bob")
    }

    @Test("Sort handles missing values gracefully")
    func sortHandlesMissingValues() {
        let rows = [
            QueryResultRow(id: 0, values: ["Charlie"]),
            QueryResultRow(id: 1, values: [nil]),
            QueryResultRow(id: 2, values: ["Alice"]),
        ]

        let sortColumnIndex = 0
        let keys: [String] = rows.map { row in
            sortColumnIndex < row.values.count ? (row.values[sortColumnIndex] ?? "") : ""
        }

        var indices = Array(0..<rows.count)
        indices.sort { keys[$0].localizedStandardCompare(keys[$1]) == .orderedAscending }

        // Empty string (nil) sorts first, then Alice, then Charlie
        #expect(rows[indices[0]].values[0] == nil)
        #expect(rows[indices[1]].values[0] == "Alice")
        #expect(rows[indices[2]].values[0] == "Charlie")
    }
}
