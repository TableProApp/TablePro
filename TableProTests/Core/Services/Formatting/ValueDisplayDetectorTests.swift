//
//  ValueDisplayDetectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ValueDisplayDetector")
@MainActor
struct ValueDisplayDetectorTests {
    private func detect(
        column: String,
        type: ColumnType,
        samples: [PluginCellValue]
    ) -> ValueDisplayFormat? {
        ValueDisplayDetector.detect(
            columns: [column],
            columnTypes: [type],
            sampleValues: samples.map { [$0] }
        )[0]
    }

    @Test("A binary column holding UTF-8 reads as text")
    func binaryTextDetected() {
        let format = detect(
            column: "payload",
            type: .blob(rawType: "VARBINARY(255)"),
            samples: [.bytes(Data("hello".utf8)), .bytes(Data("world".utf8))]
        )

        #expect(format == .text)
    }

    @Test("A binary column holding hashes stays raw")
    func binaryHashNotDetected() {
        let format = detect(
            column: "digest",
            type: .blob(rawType: "BINARY(20)"),
            samples: [.bytes(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))]
        )

        #expect(format == nil)
    }

    @Test("One binary value among readable ones keeps the whole column raw")
    func mixedColumnNotDetected() {
        let format = detect(
            column: "payload",
            type: .blob(rawType: "VARBINARY(255)"),
            samples: [.bytes(Data("hello".utf8)), .bytes(Data([0xFF, 0xFE]))]
        )

        #expect(format == nil)
    }

    @Test("A column of nulls says nothing")
    func nullColumnNotDetected() {
        let format = detect(column: "payload", type: .blob(rawType: "BLOB"), samples: [.null, .null])

        #expect(format == nil)
    }

    @Test("A column of empty values says nothing")
    func emptyColumnNotDetected() {
        let format = detect(
            column: "payload",
            type: .blob(rawType: "BINARY(16)"),
            samples: [.bytes(Data(repeating: 0, count: 16)), .bytes(Data())]
        )

        #expect(format == nil)
    }

    @Test("A driver that decoded the binary itself keeps its own answer")
    func driverDecodedColumnNotDetected() {
        let format = detect(
            column: "payload",
            type: .blob(rawType: "BinData"),
            samples: [.text("already decoded")]
        )

        #expect(format == nil)
    }

    @Test("Id-like sixteen-byte columns still read as UUID")
    func uuidStillWinsOnIdColumns() {
        let format = detect(
            column: "id",
            type: .blob(rawType: "BINARY(16)"),
            samples: [.bytes(Data("0123456789abcdef".utf8))]
        )

        #expect(format == .uuid)
    }

    @Test("A sixteen-byte column with no id in its name reads as text when it holds text")
    func textWinsWhereUuidDeclines() {
        let format = detect(
            column: "payload",
            type: .blob(rawType: "BINARY(16)"),
            samples: [.bytes(Data("0123456789abcdef".utf8))]
        )

        #expect(format == .text)
    }

    @Test("A trailing NUL keeps a variable-width binary column raw, and pads a fixed-width one")
    func trailingNulFollowsTheColumnWidth() {
        let value = PluginCellValue.bytes(Data([0x61, 0x00]))

        #expect(detect(column: "payload", type: .blob(rawType: "VARBINARY(255)"), samples: [value]) == nil)
        #expect(detect(column: "payload", type: .blob(rawType: "BINARY(2)"), samples: [value]) == .text)
    }

    @Test("Text columns are left alone")
    func textColumnNotDetected() {
        let format = detect(
            column: "note",
            type: .text(rawType: "VARCHAR(255)"),
            samples: [.text("hello")]
        )

        #expect(format == nil)
    }

    @Test("Timestamp detection still runs on integer columns")
    func timestampStillDetected() {
        let format = detect(
            column: "created_at",
            type: .integer(rawType: "BIGINT"),
            samples: [.text("1700000000")]
        )

        #expect(format == .unixTimestamp)
    }

    @Test("A column with no sampled rows says nothing")
    func noSamplesNotDetected() {
        let results = ValueDisplayDetector.detect(
            columns: ["payload"],
            columnTypes: [.blob(rawType: "VARBINARY(255)")],
            sampleValues: nil
        )

        #expect(results[0] == nil)
    }
}
