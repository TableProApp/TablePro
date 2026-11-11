//
//  DataGridValueToneTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DataGridValueToneTests {
    private static let baseTones: [(ColumnType?, DataGridValueTone)] = [
        (.integer(rawType: "BIGINT"), .number),
        (.decimal(rawType: "NUMERIC(10,2)"), .number),
        (.date(rawType: "DATE"), .dateTime),
        (.timestamp(rawType: "TIMESTAMPTZ"), .dateTime),
        (.datetime(rawType: "DATETIME"), .dateTime),
        (.blob(rawType: "BYTEA"), .binary),
        (.json(rawType: "JSONB"), .json),
        (.enumType(rawType: "ENUM('a','b')", values: nil), .enumeration),
        (.set(rawType: "SET('a','b')", values: ["a", "b"]), .enumeration),
        (.text(rawType: "VARCHAR(255)"), .string),
        (.text(rawType: "character varying"), .string),
        (.text(rawType: "TEXT"), .string),
        (.text(rawType: "CITEXT"), .string),
        (.text(rawType: "String"), .string),
        (.text(rawType: "Nullable(String)"), .string),
        (.text(rawType: "LowCardinality(Nullable(String))"), .string),
        (.text(rawType: "UUID"), .uuid),
        (.text(rawType: "Nullable(UUID)"), .uuid),
        (.text(rawType: "UNIQUEIDENTIFIER"), .uuid),
        (.text(rawType: "INET"), .plain),
        (.text(rawType: "INTERVAL"), .plain),
        (.text(rawType: "XML"), .plain),
        (.text(rawType: "ObjectId"), .plain),
        (.text(rawType: nil), .plain),
        (.text(rawType: ""), .plain),
        (.boolean(rawType: "BOOLEAN"), .plain),
        (.spatial(rawType: "GEOMETRY"), .plain),
        (.vector(rawType: "VECTOR(3)"), .plain),
        (.array(rawType: "TEXT[]", element: .text(rawType: "TEXT")), .plain),
        (nil, .plain),
    ]

    @Test("A column's type gives its tone", arguments: baseTones)
    func baseToneFollowsTheType(type: ColumnType?, expected: DataGridValueTone) {
        #expect(DataGridValueTone.base(of: type, declaresEnumLabels: false) == expected)
    }

    @Test("Declared labels make a text column an enum, never an array, vector or number")
    func declaredLabelsMarkTextOnly() {
        #expect(DataGridValueTone.base(of: .text(rawType: "mood"), declaresEnumLabels: true) == .enumeration)
        #expect(DataGridValueTone.base(of: .text(rawType: "mood"), declaresEnumLabels: false) == .plain)
        #expect(DataGridValueTone.base(of: .text(rawType: "VARCHAR(8)"), declaresEnumLabels: true) == .enumeration)
        let enumArray = ColumnType.array(rawType: "mood[]", element: .enumType(rawType: "mood", values: ["ok"]))
        #expect(DataGridValueTone.base(of: enumArray, declaresEnumLabels: true) == .plain)
        #expect(DataGridValueTone.base(of: .array(rawType: "INT[]", element: .integer(rawType: "INT")), declaresEnumLabels: false) == .plain)
        #expect(DataGridValueTone.base(of: .vector(rawType: "VECTOR(3)"), declaresEnumLabels: true) == .plain)
        #expect(DataGridValueTone.base(of: .integer(rawType: "INT"), declaresEnumLabels: true) == .number)
    }

    @Test("A format the formatter rendered gives the tone of what it shows, a fallback keeps the column's")
    func renderedFormatRemapsTheTone() {
        let column = DataGridColumnTone(columnType: .integer(rawType: "BIGINT"), declaresEnumLabels: false)

        #expect(column.tone(displayedAs: .unixTimestamp, isFormatted: true) == .dateTime)
        #expect(column.tone(displayedAs: .unixTimestamp, isFormatted: false) == .number)
        #expect(column.tone(displayedAs: .raw, isFormatted: true) == .number)
        #expect(column.tone(displayedAs: nil, isFormatted: false) == .number)
    }

    @Test("A plain column stays plain under every format")
    func plainColumnIgnoresFormats() {
        for format in ValueDisplayFormat.presetFormats {
            #expect(DataGridColumnTone.plain.tone(displayedAs: format, isFormatted: true) == .plain, "\(format.rawValue)")
        }
    }

    @Test("Each format names the tone of what it shows")
    func eachFormatNamesItsTone() {
        let connection = UUID()
        let expected: [(ValueDisplayFormat, DataGridValueTone?)] = [
            (.raw, nil),
            (.text, .string),
            (.uuid, .uuid),
            (.uuidSwappedTime, .uuid),
            (.unixTimestamp, .dateTime),
            (.unixTimestampMillis, .dateTime),
            (.json, .json),
            (.phpSerialized, .json),
            (.messagePack, .json),
            (.protobuf, .json),
            (.igbinary, .json),
            (.avro(schemaID: "ab12"), .json),
            (.protobufSchema(schemaID: "ab12", message: "shop.Order"), .json),
            (.schemaRegistry(connectionID: connection), .json),
        ]
        for (format, tone) in expected {
            #expect(DataGridValueTone.shown(by: format) == tone, "\(format.rawValue)")
        }
    }

    private struct FormatCase {
        let type: ColumnType
        let value: PluginCellValue
        let format: ValueDisplayFormat
        let tone: DataGridValueTone

        init(_ type: ColumnType, _ value: PluginCellValue, _ format: ValueDisplayFormat, _ tone: DataGridValueTone) {
            self.type = type
            self.value = value
            self.format = format
            self.tone = tone
        }

        var description: String { "\(format.rawValue) on \(type.rawType ?? "untyped") \(type.displayName)" }
    }

    private static let uuidBytes = Data([
        0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
        0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
    ])
    private static let messagePackMap = Data([0x81, 0xA1, 0x61, 0x01])
    private static let truncatedMessagePack = Data([0x82, 0xA7, 0x63, 0x6F, 0x6D, 0x70])

    @Test("A cell takes the tone of what the formatter shows for it")
    @MainActor
    func cellToneFollowsTheFormatter() {
        let uuidBytes = Self.uuidBytes
        let messagePackMap = Self.messagePackMap
        let truncatedMessagePack = Self.truncatedMessagePack
        let cases: [FormatCase] = [
            FormatCase(.integer(rawType: "BIGINT"), .text("1700000000"), .unixTimestamp, .dateTime),
            FormatCase(.integer(rawType: "BIGINT"), .text("1700000000000"), .unixTimestampMillis, .dateTime),
            FormatCase(.integer(rawType: "BIGINT"), .text("soon"), .unixTimestamp, .number),
            FormatCase(.blob(rawType: "BINARY(16)"), .bytes(uuidBytes), .uuid, .uuid),
            FormatCase(.blob(rawType: "BINARY(16)"), .bytes(uuidBytes), .uuidSwappedTime, .uuid),
            FormatCase(.blob(rawType: "BINARY(16)"), .bytes(uuidBytes.prefix(8)), .uuid, .binary),
            FormatCase(.blob(rawType: "BLOB"), .bytes(Data("hello".utf8)), .text, .string),
            FormatCase(.blob(rawType: "BLOB"), .bytes(messagePackMap), .messagePack, .json),
            FormatCase(.blob(rawType: "BLOB"), .bytes(truncatedMessagePack), .messagePack, .binary),
            FormatCase(.text(rawType: "TEXT"), .text(#"{"a":1}"#), .json, .json),
            FormatCase(.text(rawType: "TEXT"), .text("a:0:{}"), .phpSerialized, .json),
            FormatCase(.text(rawType: "VARCHAR(40)"), .text("pending"), .json, .string),
            FormatCase(.text(rawType: "VARCHAR(40)"), .text(#"{"a":"#), .json, .string),
            FormatCase(.text(rawType: "VARCHAR(40)"), .text("pending"), .phpSerialized, .string),
            FormatCase(.text(rawType: "CHAR(36)"), .text("AF49453B7F2FFB58FCD32BD399599FA5"), .uuid, .uuid),
            FormatCase(.text(rawType: "CHAR(36)"), .text("af49453b-7f2f-fb58-fcd3-2bd399599fa5"), .uuid, .uuid),
            FormatCase(.text(rawType: "VARCHAR(40)"), .text("not a uuid"), .uuid, .string),
            FormatCase(.text(rawType: nil), .text("AF49453B7F2FFB58FCD32BD399599FA5"), .uuid, .uuid),
            FormatCase(.integer(rawType: "INT"), .text("42"), .uuid, .number),
            FormatCase(.integer(rawType: "INT"), .text("42"), .json, .number),
            FormatCase(.decimal(rawType: "DOUBLE"), .text("1700000000"), .unixTimestamp, .number),
            FormatCase(.text(rawType: "TEXT"), .text("1700000000"), .unixTimestamp, .string),
            FormatCase(.text(rawType: "TEXT"), .text("hello"), .text, .string),
            FormatCase(.blob(rawType: "BLOB"), .bytes(messagePackMap), .json, .binary),
            FormatCase(.blob(rawType: "BLOB"), .bytes(uuidBytes), .raw, .binary),
            FormatCase(.text(rawType: "INET"), .text("10.0.0.1"), .uuid, .plain),
        ]
        for testCase in cases {
            let shown = CellDisplayFormatter.display(
                testCase.value,
                columnType: testCase.type,
                displayFormat: testCase.format,
                databaseType: nil
            )
            let column = DataGridColumnTone(columnType: testCase.type, declaresEnumLabels: false)

            #expect(column.tone(displayedAs: testCase.format, isFormatted: shown.isFormatted) == testCase.tone, "\(testCase.description)")
        }
    }

    @Test("A MongoDB binary value under a UUID format stays binary, as the formatter shows it")
    @MainActor
    func mongoBinaryRefusesUUID() {
        let column = DataGridColumnTone(columnType: .blob(rawType: "BinData"), declaresEnumLabels: false)
        for format in [ValueDisplayFormat.uuid, .uuidSwappedTime] {
            let shown = CellDisplayFormatter.display(
                .bytes(Self.uuidBytes),
                columnType: .blob(rawType: "BinData"),
                displayFormat: format,
                databaseType: .mongodb
            )
            #expect(column.tone(displayedAs: format, isFormatted: shown.isFormatted) == .binary, "\(format.rawValue)")
        }
    }

    @Test("The formatter only reports a format it applies to the column")
    @MainActor
    func formattedOnlyWhereTheFormatApplies() {
        let types: [ColumnType] = [
            .text(rawType: "TEXT"), .integer(rawType: "INT"), .decimal(rawType: "DECIMAL"), .blob(rawType: "BLOB"),
            .json(rawType: "JSON"), .date(rawType: "DATE"), .boolean(rawType: "BOOL"),
        ]
        let values: [PluginCellValue] = [
            .text("1700000000"), .text("AF49453B7F2FFB58FCD32BD399599FA5"), .text(#"{"a":1}"#), .bytes(Self.uuidBytes),
            .bytes(Self.messagePackMap), .null,
        ]
        for type in types {
            for format in ValueDisplayFormat.presetFormats {
                for value in values {
                    let shown = CellDisplayFormatter.display(value, columnType: type, displayFormat: format, databaseType: nil)
                    let applies = format != .raw && format.isApplicable(to: type)
                    #expect(!shown.isFormatted || applies, "\(format.rawValue) on \(type.displayName)")
                }
            }
        }
    }
}
