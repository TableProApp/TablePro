//
//  ValueDisplayFormatTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ValueDisplayFormatTests {
    @Test("rawValue strings stay stable")
    func rawValueStability() {
        #expect(ValueDisplayFormat.raw.rawValue == "raw")
        #expect(ValueDisplayFormat.text.rawValue == "text")
        #expect(ValueDisplayFormat.uuid.rawValue == "uuid")
        #expect(ValueDisplayFormat.unixTimestamp.rawValue == "unixTimestamp")
        #expect(ValueDisplayFormat.unixTimestampMillis.rawValue == "unixTimestampMillis")
        #expect(ValueDisplayFormat.json.rawValue == "json")
        #expect(ValueDisplayFormat.phpSerialized.rawValue == "phpSerialized")
        #expect(ValueDisplayFormat.uuidSwappedTime.rawValue == "uuidSwappedTime")
        #expect(ValueDisplayFormat.messagePack.rawValue == "messagePack")
        #expect(ValueDisplayFormat.protobuf.rawValue == "protobuf")
        #expect(ValueDisplayFormat.igbinary.rawValue == "igbinary")
        #expect(ValueDisplayFormat.avro(schemaID: "ab12").rawValue == "avro:ab12")
    }

    @Test("Every format reads back from its stored form, an Avro one with its schema ID")
    func codableRoundTrip() throws {
        let formats: [String: ValueDisplayFormat] = [
            "a": .messagePack, "b": .igbinary, "c": .avro(schemaID: String(repeating: "ab12", count: 8)), "d": .raw,
        ]
        let data = try JSONEncoder().encode(formats)
        #expect(try JSONDecoder().decode([String: ValueDisplayFormat].self, from: data) == formats)
        #expect(try JSONDecoder().decode([String: ValueDisplayFormat].self, from: Data(#"{"x":"protobuf"}"#.utf8))
            == ["x": .protobuf])
        #expect(ValueDisplayFormat(rawValue: "avro:") == nil)
        #expect(ValueDisplayFormat(rawValue: "avro:ab12") == nil)
        #expect(ValueDisplayFormat(rawValue: "avro:" + String(repeating: "AB12", count: 8)) == nil)
        #expect(ValueDisplayFormat(rawValue: "nope") == nil)
    }

    @Test("only the formats that produce characters count as rendering binary as text")
    func rendersBinaryAsText() {
        #expect(ValueDisplayFormat.text.rendersBinaryAsText)
        #expect(ValueDisplayFormat.uuid.rendersBinaryAsText)
        #expect(ValueDisplayFormat.uuidSwappedTime.rendersBinaryAsText)
        #expect(ValueDisplayFormat.messagePack.rendersBinaryAsText)
        #expect(ValueDisplayFormat.protobuf.rendersBinaryAsText)
        #expect(ValueDisplayFormat.igbinary.rendersBinaryAsText)
        #expect(ValueDisplayFormat.avro(schemaID: "ab12").rendersBinaryAsText)
        #expect(!ValueDisplayFormat.raw.rendersBinaryAsText)
        #expect(!ValueDisplayFormat.unixTimestamp.rendersBinaryAsText)
        #expect(!ValueDisplayFormat.json.rendersBinaryAsText)
    }

    @Test("text column applicable formats include json and phpSerialized")
    func applicableForText() {
        let formats = ValueDisplayFormat.applicableFormats(for: .text(rawType: "TEXT"))
        #expect(formats.contains(.json))
        #expect(formats.contains(.phpSerialized))
        #expect(formats.contains(.uuid))
        #expect(formats.contains(.raw))
        #expect(!formats.contains(.unixTimestamp))
        #expect(!formats.contains(.text))
    }

    @Test("integer column applicable formats do not include json or phpSerialized")
    func applicableForInteger() {
        let formats = ValueDisplayFormat.applicableFormats(for: .integer(rawType: "INT"))
        #expect(!formats.contains(.json))
        #expect(!formats.contains(.phpSerialized))
        #expect(!formats.contains(.text))
        #expect(formats.contains(.unixTimestamp))
    }

    @Test("blob column offers text, both UUID orders and the binary decoders, but not json or phpSerialized")
    func applicableForBlob() {
        let formats = ValueDisplayFormat.applicableFormats(for: .blob(rawType: "BLOB"))
        #expect(!formats.contains(.json))
        #expect(!formats.contains(.phpSerialized))
        #expect(formats == [.raw, .text, .uuid, .uuidSwappedTime, .messagePack, .protobuf, .igbinary])
    }

    @Test("The binary decoders and the swapped UUID stay off text and integer columns")
    func binaryFormatsAreBlobOnly() {
        for columnType in [ColumnType.text(rawType: "TEXT"), .integer(rawType: "INT")] {
            let formats = ValueDisplayFormat.applicableFormats(for: columnType)
            #expect(!formats.contains(.uuidSwappedTime))
            #expect(!formats.contains(.messagePack))
            #expect(!formats.contains(.protobuf))
            #expect(!formats.contains(.igbinary))
            #expect(!ValueDisplayFormat.avro(schemaID: "ab12").isApplicable(to: columnType))
        }
    }

    @Test("MongoDB binary columns do not offer generic UUID formatting")
    func mongoBinaryDoesNotOfferUuid() {
        let formats = ValueDisplayFormat.applicableFormats(
            for: .blob(rawType: "BLOB(3)"),
            databaseType: .mongodb
        )

        #expect(!formats.contains(.uuid))
        #expect(formats == [.raw, .text, .messagePack, .protobuf, .igbinary])
    }

    @Test("nil column type returns only raw")
    func applicableForNil() {
        let formats = ValueDisplayFormat.applicableFormats(for: nil)
        #expect(formats == [.raw])
    }

    @Test("Duplicate column labels receive occurrence-scoped storage keys")
    func duplicateColumnStorageKeys() {
        let keys = ValueDisplayFormatColumnKey.storageKeys(for: ["value", "name", "value"])

        #expect(keys[0] != keys[2])
        #expect(keys[1] == "name")
        #expect(keys[0].hasSuffix(":0:value"))
        #expect(keys[2].hasSuffix(":1:value"))
    }

    @Test("Inspector uses raw when the live format array has no column entry")
    func inspectorDoesNotFallBackPastLiveFormats() {
        let format = InspectorValueDisplayFormatResolver.resolve(
            columnIndex: 0,
            activeFormats: [],
            storedFormat: .uuid,
            columnType: .blob(rawType: "BLOB"),
            databaseType: .sqlite
        )

        #expect(format == .raw)
    }

    @Test("Inspector rejects a stored format that does not match the column")
    func inspectorRejectsStaleStoredFormat() {
        let format = InspectorValueDisplayFormatResolver.resolve(
            columnIndex: 0,
            activeFormats: nil,
            storedFormat: .unixTimestamp,
            columnType: .text(rawType: "TEXT"),
            databaseType: .sqlite
        )

        #expect(format == .raw)
    }

    @Test("Setting a format pads the array to the full column count")
    func displayFormatArrayPadsToColumnCount() {
        let formats = DisplayFormatArray.setting(.uuid, at: 0, in: [], columnCount: 3)

        #expect(formats == [.uuid, nil, nil])
    }

    @Test("Setting a format keeps the other columns and never shrinks the array")
    func displayFormatArrayPreservesOtherColumns() {
        let formats = DisplayFormatArray.setting(
            .unixTimestamp,
            at: 2,
            in: [.uuid, nil, nil, .json],
            columnCount: 3
        )

        #expect(formats == [.uuid, nil, .unixTimestamp, .json])
    }
}
