//
//  MongoStreamProjectionTests.swift
//  TableProTests
//
//  Tests for MongoStreamProjection (compiled via symlink from MongoDBDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

struct MongoStreamProjectionTests {
    private func text(_ value: Any, _ kind: BsonValueKind) -> PluginCellValue {
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

    private var fullSample: [[String: Any]] {
        (1...MongoStreamProjection.sampleSize).map { ["_id": Int32($0), "name": "user \($0)"] }
    }

    private func census(_ tallies: [(String, Int64, Any)]) -> MongoFieldCensus {
        MongoFieldCensus(tallies: tallies.map { MongoFieldCensus.Tally(field: $0.0, documents: $0.1, example: $0.2) })
    }

    private func cell(_ value: Any, _ kind: BsonValueKind) -> PluginCellValue {
        BsonDocumentFlattener.cellValue(for: value, kind: kind, representation: .unspecified)
    }

    @Test("A field the census reports after the sample joins the header with its own type")
    func censusFieldJoinsTheHeader() throws {
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let projection = MongoStreamProjection(
            sample: fullSample,
            census: census([
                ("_id", 201, Int32(1)),
                ("name", 201, "user 1"),
                ("late", 1, seen)
            ]),
            representation: .unspecified
        )

        #expect(projection.columns == ["_id", "name", "late"])
        let lateIndex = try #require(projection.columns.firstIndex(of: "late"))
        #expect(projection.columnTypeNames[lateIndex] == "TIMESTAMP")

        let row = projection.row(for: ["_id": Int32(201), "name": "user 201", "late": seen], convert: cell)
        #expect(row[lateIndex] != .null)
    }

    @Test("Without a census the header is the sample's columns")
    func missingCensusKeepsTheSampledColumns() {
        let projection = MongoStreamProjection(sample: fullSample, census: nil, representation: .unspecified)
        #expect(projection.columns == ["_id", "name"])
        #expect(projection.columnTypeNames == ["INTEGER", "VARCHAR"])
    }

    @Test("Sampled columns keep their order and census fields follow in name order")
    func censusFieldsFollowTheSampledColumns() {
        let projection = MongoStreamProjection(
            sample: fullSample,
            census: census([("zeta", 4, "z"), ("name", 201, "user 1"), ("alpha", 2, true)]),
            representation: .unspecified
        )
        #expect(projection.columns == ["_id", "name", "alpha", "zeta"])
        #expect(projection.columnTypeNames == ["INTEGER", "VARCHAR", "BOOLEAN", "VARCHAR"])
    }

    @Test("A census field takes the type most of its documents hold, and nulls do not vote")
    func censusFieldTakesTheMajorityType() {
        let projection = MongoStreamProjection(
            sample: fullSample,
            census: census([
                ("mixed", 3, "text"),
                ("mixed", 10, Int64(5_000_000_000)),
                ("dated", 500, NSNull()),
                ("dated", 1, Date(timeIntervalSince1970: 0)),
                ("empty", 7, NSNull())
            ]),
            representation: .unspecified
        )
        #expect(projection.columns == ["_id", "name", "dated", "empty", "mixed"])
        #expect(projection.columnTypeNames == ["INTEGER", "VARCHAR", "TIMESTAMP", "VARCHAR", "BIGINT"])
    }

    @Test("A sampled column that held only nulls takes the type the census found for it")
    func censusTypesAColumnTheSampleHeldOnlyNullsIn() {
        let sample: [[String: Any]] = (1...MongoStreamProjection.sampleSize).map {
            ["_id": Int32($0), "deletedAt": NSNull()]
        }
        let deleted = Date(timeIntervalSince1970: 1_700_000_000)
        let projection = MongoStreamProjection(
            sample: sample,
            census: census([("deletedAt", 200, NSNull()), ("deletedAt", 40, deleted)]),
            representation: .unspecified
        )

        #expect(projection.columns == ["_id", "deletedAt"])
        #expect(projection.columnTypeNames == ["INTEGER", "TIMESTAMP"])
        let row = projection.row(for: ["_id": Int32(201), "deletedAt": deleted], convert: cell)
        #expect(row[1] != .null)
    }

    @Test("The census never changes the type the sample chose for a sampled column")
    func censusLeavesSampledTypesAlone() {
        let projection = MongoStreamProjection(
            sample: fullSample,
            census: census([("name", 10_000, Int32(3))]),
            representation: .unspecified
        )
        #expect(projection.columns == ["_id", "name"])
        #expect(projection.columnTypeNames == ["INTEGER", "VARCHAR"])
    }

    @Test("A field the header left out is reported, and an announced one is not")
    func fieldsOutsideTheHeaderAreReported() {
        let projection = MongoStreamProjection(sample: fullSample, census: nil, representation: .unspecified)
        let late = projection.unannouncedFields(in: ["_id": Int32(201), "name": "user 201", "late": true])
        #expect(late == ["late"])
        #expect(projection.unannouncedFields(in: ["_id": Int32(202), "name": "user 202"]).isEmpty)
    }

    @Test("The fallback header announces only _id")
    func fallbackHeaderAnnouncesOnlyTheId() {
        let projection = MongoStreamProjection(columns: [], columnTypeNames: [])
        #expect(projection.unannouncedFields(in: ["_id": 1, "name": "Ada"]) == ["name"])
    }
}
