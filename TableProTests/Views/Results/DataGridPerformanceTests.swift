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
        let rows = TestFixtures.makeRows(count: 5, columns: ["name", "age"])

        let sortColumnIndex = 0
        let keys: [String] = rows.map { row in
            sortColumnIndex < row.count ? (row[sortColumnIndex] ?? "") : ""
        }

        var indices1 = Array(0..<rows.count)
        indices1.sort { keys[$0].compare(keys[$1], options: [.numeric]) == .orderedAscending }

        var indices2 = Array(0..<rows.count)
        indices2.sort {
            let v1 = sortColumnIndex < rows[$0].count ? (rows[$0][sortColumnIndex] ?? "") : ""
            let v2 = sortColumnIndex < rows[$1].count ? (rows[$1][sortColumnIndex] ?? "") : ""
            return RowSortComparator.compare(v1, v2, columnType: nil) == .orderedAscending
        }

        #expect(indices1 == indices2)
    }

    @Test("Sort with multiple columns and mixed directions")
    func multiColumnMixedDirections() {
        let rows: [[String?]] = [
            ["Alice", "30"],
            ["Bob", "25"],
            ["Alice", "20"],
            ["Bob", "35"],
        ]

        var indices = Array(0..<rows.count)
        indices.sort { i1, i2 in
            let v1 = rows[i1][0] ?? ""
            let v2 = rows[i2][0] ?? ""
            let result = RowSortComparator.compare(v1, v2, columnType: nil)
            if result != .orderedSame {
                return result == .orderedAscending
            }
            let w1 = rows[i1][1] ?? ""
            let w2 = rows[i2][1] ?? ""
            let result2 = RowSortComparator.compare(w1, w2, columnType: nil)
            return result2 == .orderedDescending
        }

        // Alice should come first, with age 30 before 20 (descending)
        #expect(rows[indices[0]][0] == "Alice")
        #expect(rows[indices[0]][1] == "30")
        #expect(rows[indices[1]][0] == "Alice")
        #expect(rows[indices[1]][1] == "20")
        #expect(rows[indices[2]][0] == "Bob")
    }

    @Test("Sort handles missing values gracefully")
    func sortHandlesMissingValues() {
        let rows: [[String?]] = [
            ["Charlie"],
            [nil],
            ["Alice"],
        ]

        let sortColumnIndex = 0
        let keys: [String] = rows.map { row in
            sortColumnIndex < row.count ? (row[sortColumnIndex] ?? "") : ""
        }

        var indices = Array(0..<rows.count)
        indices.sort { keys[$0].compare(keys[$1], options: [.numeric]) == .orderedAscending }

        // Empty string (nil) sorts first, then Alice, then Charlie
        #expect(rows[indices[0]][0] == nil)
        #expect(rows[indices[1]][0] == "Alice")
        #expect(rows[indices[2]][0] == "Charlie")
    }
}
