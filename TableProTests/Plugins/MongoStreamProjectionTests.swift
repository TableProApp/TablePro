//
//  MongoStreamProjectionTests.swift
//  TableProTests
//
//  Tests for MongoStreamProjection (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Stream Projection")
struct MongoStreamProjectionTests {
    private func text(_ value: Any) -> PluginCellValue {
        PluginCellValue.fromOptional("\(value)")
    }

    @Test("Header carries the announced columns and type names")
    func headerCarriesColumns() {
        let projection = MongoStreamProjection(
            columns: ["_id", "name"],
            columnTypeNames: ["ObjectId", "VARCHAR"]
        )
        #expect(projection.header.columns == ["_id", "name"])
        #expect(projection.header.columnTypeNames == ["ObjectId", "VARCHAR"])
    }

    @Test("An empty column set falls back to _id")
    func emptyColumnsFallBackToId() {
        let projection = MongoStreamProjection(columns: [], columnTypeNames: [])
        #expect(projection.columns == ["_id"])
        #expect(projection.columnTypeNames == ["VARCHAR"])
    }

    @Test("Missing type names are padded so the header stays balanced")
    func missingTypeNamesArePadded() {
        let projection = MongoStreamProjection(columns: ["a", "b", "c"], columnTypeNames: ["INTEGER"])
        #expect(projection.columnTypeNames == ["INTEGER", "VARCHAR", "VARCHAR"])
    }

    @Test("A document missing a column yields null in that slot")
    func missingFieldBecomesNull() {
        let projection = MongoStreamProjection(columns: ["_id", "name", "email"], columnTypeNames: [])
        let row = projection.row(for: ["_id": 1, "email": "a@b.c"], convert: text)
        #expect(row == [.text("1"), .null, .text("a@b.c")])
    }

    @Test("Fields outside the column plan never widen a row")
    func extraFieldsDoNotWidenTheRow() {
        let projection = MongoStreamProjection(columns: ["_id", "name"], columnTypeNames: [])
        let row = projection.row(for: ["_id": 1, "name": "Ada", "addedLater": true], convert: text)
        #expect(row.count == projection.columns.count)
        #expect(row == [.text("1"), .text("Ada")])
    }

    @Test("Every row in a heterogeneous batch matches the header width")
    func heterogeneousDocumentsStayAligned() {
        let documents: [[String: Any]] = [
            ["_id": 1, "name": "Ada"],
            ["_id": 2, "nickname": "Grace"],
            ["_id": 3]
        ]
        let projection = MongoStreamProjection(columns: ["_id", "name", "nickname"], columnTypeNames: [])

        for document in documents {
            #expect(projection.row(for: document, convert: text).count == projection.header.columns.count)
        }
    }

    @Test("Column order drives the row, not the document key order")
    func columnOrderDrivesTheRow() {
        let projection = MongoStreamProjection(columns: ["z", "a"], columnTypeNames: [])
        let row = projection.row(for: ["a": "first", "z": "last"], convert: text)
        #expect(row == [.text("last"), .text("first")])
    }
}
