//
//  QueryResultRowTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("QueryResultRow")
struct QueryResultRowTests {
    @Test("Rows with same id and same values are equal")
    func sameIdSameValues() {
        let row1 = QueryResultRow(id: 1, values: ["a", "b", nil])
        let row2 = QueryResultRow(id: 1, values: ["a", "b", nil])
        #expect(row1 == row2)
    }

    @Test("Rows with same id but different values are not equal")
    func sameIdDifferentValues() {
        let row1 = QueryResultRow(id: 1, values: ["a", "b"])
        let row2 = QueryResultRow(id: 1, values: ["a", "c"])
        #expect(row1 != row2)
    }

    @Test("Rows with different id are not equal")
    func differentId() {
        let row1 = QueryResultRow(id: 1, values: ["a"])
        let row2 = QueryResultRow(id: 2, values: ["a"])
        #expect(row1 != row2)
    }

    @Test("Rows with same id but different value count are not equal")
    func differentValueCount() {
        let row1 = QueryResultRow(id: 1, values: ["a", "b"])
        let row2 = QueryResultRow(id: 1, values: ["a"])
        #expect(row1 != row2)
    }

    @Test("Empty values rows with same id are equal")
    func emptyValues() {
        let row1 = QueryResultRow(id: 0, values: [])
        let row2 = QueryResultRow(id: 0, values: [])
        #expect(row1 == row2)
    }
}
