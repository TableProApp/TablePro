//
//  RoundTripFixture.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit

// One column per SQLite storage class, filled with the values a writer and a reader most often
// disagree on.
enum RoundTripFixture {
    static let table = "round_trip"

    static let createStatement = """
        CREATE TABLE "round_trip" (
          "id" INTEGER PRIMARY KEY,
          "whole" INTEGER,
          "fraction" REAL,
          "label" TEXT,
          "payload" BLOB,
          "amount" NUMERIC
        )
        """

    static let labels: [StoredValue] = [
        .text(""), .text("plain"), .text("comma, inside"), .text("semi;colon"), .text("pipe|bar"),
        .text("tab\there"), .text("say \"hi\""), .text("it's"), .text("line\nbreak"), .text("crlf\r\nbreak"),
        .text("lone\rreturn"), .text("  padded  "), .text("Unicode ü 日本語 😀"), .text("NULL"), .text("null"),
        .text("-5"), .text("+5"), .text("-2.5e3"), .text("=1+1"), .text("@SUM(A1)"), .text("-- not a comment"),
        .text("/* nor this */"), .text("0123"), .text("1e5"), .text("true"), .text("TRUE"), .text("False"),
        .text("back\\slash"), .text("#hash"), .text("\""), .text("'"), .text("0x41"), .text("control\u{1}char"),
        .null,
    ]

    static let wholes: [StoredValue] = [
        .integer(0), .integer(1), .integer(-1), .integer(42), .integer(-7), .integer(.max), .integer(.min), .null,
    ]

    static let fractions: [StoredValue] = [
        .real(0.5), .real(-2.25), .real(0.1), .real(0.1 + 0.2), .real(1.0 / 3), .real(1e300), .real(-1e-300),
        .real(3), .null,
    ]

    static let payloads: [StoredValue] = [
        .blob(Data()), .blob(Data([0])), .blob(Data([0xFF, 0x00, 0x10])), .blob(Data("AB".utf8)),
        .blob(Data(0 ... 255)), .null,
    ]

    static let amounts: [StoredValue] = [.integer(7), .real(12.5), .integer(-3), .null]

    static let rows: [[StoredValue]] = labels.indices.map { index in
        [
            .integer(Int64(index + 1)),
            wholes[index % wholes.count],
            fractions[index % fractions.count],
            labels[index],
            payloads[index % payloads.count],
            amounts[index % amounts.count],
        ]
    }

    static func database() throws -> RoundTripDatabase {
        let database = try RoundTripDatabase()
        try database.execute(createStatement)
        for row in rows {
            try database.insert(row, into: table)
        }
        return database
    }

    static func emptyDatabase() throws -> RoundTripDatabase {
        let database = try RoundTripDatabase()
        try database.execute(createStatement)
        return database
    }

    static let bulkTable = "bulk"

    // About 4 MB, so a dump splits into several 1 MB parts and gzip sees more than one buffer.
    static let bulkRows: [[StoredValue]] = (0 ..< 4_000).map { index in
        [
            .integer(Int64(index + 1)),
            .text("row \(index) 'quoted' \"double\" é " + String(repeating: "x", count: 900 + index % 97)),
            .blob(Data((0 ..< 64).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) })),
            .real(Double(index) / 7),
        ]
    }

    // The fixture table and the bulk table side by side, for a dump of more than one table.
    static func databaseWithBulk() throws -> RoundTripDatabase {
        let database = try self.database()
        try database.execute("""
            CREATE TABLE "bulk" ("id" INTEGER PRIMARY KEY, "body" TEXT, "bytes" BLOB, "ratio" REAL)
            """)
        for row in bulkRows {
            try database.insert(row, into: bulkTable)
        }
        return database
    }

    static func exportTable(_ name: String = table, optionValues: [Bool] = []) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "", tableType: "table", optionValues: optionValues)
    }
}

// What a format cannot carry, applied to the stored rows to give the rows an import gets back.
struct FormatLimits: Sendable {
    var emptyTextIsNull = false
    var binary: @Sendable (Data) -> StoredValue = { .blob($0) }
    var text: @Sendable (String) -> String = { $0 }

    func carried(_ rows: [[StoredValue]]) -> [[StoredValue]] {
        rows.map { row in
            row.map { value in
                switch value {
                case .text(let text) where text.isEmpty && emptyTextIsNull:
                    return .null
                case .text(let text):
                    return .text(self.text(text))
                case .blob(let data):
                    return binary(data)
                default:
                    return value
                }
            }
        }
    }

    static let exact = FormatLimits()

    static func hex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02X", $0) }.joined()
    }
}
