//
//  BinaryDisplayFormatTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct BinaryDisplayFormatTests {
    /// `HEX(UUID_TO_BIN('6ccd780c-baba-1026-9564-5b8c656024db', 1))` on MySQL 8.4.
    private static let swappedStored = BinaryFixture.data("1026BABA6CCD780C95645B8C656024DB")
    private static let blob = ColumnType.blob(rawType: "BINARY(16)")

    @Test("UUID (Swapped Time) renders a UUID_TO_BIN(uuid, 1) value as the UUID passed in")
    func swappedTimeBytes() {
        let result = CellDisplayFormatter.format(.bytes(Self.swappedStored), columnType: Self.blob, displayFormat: .uuidSwappedTime)
        #expect(result == "6ccd780c-baba-1026-9564-5b8c656024db")
        let stored = CellDisplayFormatter.format(.bytes(Self.swappedStored), columnType: Self.blob, displayFormat: .uuid)
        #expect(stored == "1026baba-6ccd-780c-9564-5b8c656024db")
    }

    @Test("A driver that hands the bytes over as text reads the same")
    func swappedTimeText() {
        let text = String(data: Self.swappedStored, encoding: .isoLatin1) ?? ""
        #expect(ValueDisplayFormatter.apply(text, format: .uuidSwappedTime) == "6ccd780c-baba-1026-9564-5b8c656024db")
        #expect(ValueDisplayFormatter.apply("0x1026BABA6CCD780C95645B8C656024DB", format: .uuidSwappedTime)
            == "6ccd780c-baba-1026-9564-5b8c656024db")
    }

    @Test("A hex string with non-ASCII digits is left as it is")
    func swappedTimeRejectsWideDigits() {
        let wide = String(repeating: "Ａ", count: 32)
        #expect(ValueDisplayFormatter.apply(wide, format: .uuidSwappedTime) == wide)
    }

    @Test("Swapping is its own inverse over the stored bytes")
    func swapRoundTrip() {
        let uuid = Array(0..<16).map { UInt8($0) }
        let stored = UUIDByteOrder.swappedTime.storedBytes(fromUUID: uuid)
        #expect(stored == [6, 7, 4, 5, 0, 1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15])
        #expect(UUIDByteOrder.swappedTime.uuidBytes(fromStored: stored) == uuid)
    }

    @Test("MongoDB binary columns offer no swapped UUID")
    func swappedTimeNotOnMongo() {
        let result = CellDisplayFormatter.format(
            .bytes(Self.swappedStored),
            columnType: .blob(rawType: "BLOB(3)"),
            displayFormat: .uuidSwappedTime,
            databaseType: .mongodb
        )
        #expect(result == "0x1026BABA6CCD780C95645B8C656024DB")
    }

    @Test("Each decoder renders its value in the cell")
    func decodersRender() {
        let blob = ColumnType.blob(rawType: "BLOB")
        #expect(CellDisplayFormatter.format(
            .bytes(BinaryFixture.data("82a7636f6d70616374c3a6736368656d6100")), columnType: blob, displayFormat: .messagePack
        ) == #"{"compact":true,"schema":0}"#)
        #expect(CellDisplayFormatter.format(
            .bytes(BinaryFixture.data("0801131a08687474703a2f2f782002142a03656e64")), columnType: blob, displayFormat: .protobuf
        ) == #"1: 1 2 { 3: "http://x" 4: 2 } 5: "end""#)
    }

    @Test("A value that does not decode falls back to hex")
    func brokenFallsBackToHex() {
        let blob = ColumnType.blob(rawType: "BLOB")
        let broken = BinaryFixture.data("82a7636f6d70")
        #expect(CellDisplayFormatter.format(.bytes(broken), columnType: blob, displayFormat: .messagePack) == "0x82A7636F6D70")
        #expect(CellDisplayFormatter.format(.bytes(broken), columnType: blob, displayFormat: .protobuf) == "0x82A7636F6D70")
    }

    @Test("A decoded value too long for the cell is cut with a marker")
    func longValueIsCut() {
        var hex = "dd00007530"
        hex += String(repeating: "00", count: 30_000)
        let text = ValueDisplayFormatter.apply(BinaryFixture.data(hex), format: .messagePack) ?? ""
        #expect(text.hasPrefix("[0,0,0"))
        #expect(text.hasSuffix(BinaryTextDecoder.truncationMarker))
        #expect((text as NSString).length <= BinaryValueDecoding.maxTextLength + 1)
    }

    @Test("Text cut short by non-ASCII characters still carries the marker")
    func nonASCIITruncationIsMarked() {
        var messagePack = Data([0xDC, 0x2E, 0xE0])
        for _ in 0..<12_000 {
            messagePack.append(contentsOf: [0xA2, 0xC3, 0xA9])
        }
        let text = BinaryValueDecoding.text(messagePack, format: .messagePack) ?? ""
        #expect(text.hasPrefix(#"["é","é""#))
        #expect(text.hasSuffix(BinaryTextDecoder.truncationMarker))
    }

    @Test("One large scalar is written only as far as the cell can show")
    func largeScalarIsBounded() {
        let payload = Data(repeating: 0xAB, count: 1_000_000)
        var messagePack = Data([0xC6, 0x00, 0x0F, 0x42, 0x40])
        messagePack.append(payload)
        let text = BinaryValueDecoding.text(messagePack, format: .messagePack) ?? ""
        #expect(text.hasPrefix("\"0xABAB"))
        #expect((text as NSString).length <= BinaryValueDecoding.maxTextLength + 1)

        var protobuf = Data([0x0A, 0xC0, 0x84, 0x3D])
        protobuf.append(payload)
        let fields = BinaryValueDecoding.text(protobuf, format: .protobuf) ?? ""
        #expect(fields.hasPrefix(#"1: "\253\253"#))
        #expect((fields as NSString).length <= BinaryValueDecoding.maxTextLength + 1)
    }

    @Test("The viewer document says why a value did not decode")
    func documentFailure() {
        guard case .failed(let error) = BinaryValueDecoding.document(BinaryFixture.data("82a7636f6d70"), format: .messagePack) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == BinaryValueDecodeError(kind: .unexpectedEnd, offset: 6))
        #expect(!error.reason.isEmpty)
    }

    @Test("The viewer document reads a Schema Registry frame")
    func documentFraming() {
        let document = BinaryValueDecoding.document(BinaryFixture.data("000000002a00089601"), format: .protobuf)
        guard case .decoded(_, let text, let note) = document else {
            Issue.record("expected a decoded value")
            return
        }
        #expect(text == "1: 150\n")
        #expect(note?.contains("42") == true)
    }

    @Test("igbinary and Avro render in the cell, and a broken value falls back to hex")
    func igbinaryAndAvroRender() throws {
        let blob = ColumnType.blob(rawType: "BLOB")
        let igbinary = BinaryFixture.data("000000021705506f696e7414011101780601")
        #expect(CellDisplayFormatter.format(.bytes(igbinary), columnType: blob, displayFormat: .igbinary)
            == #"O:5:"Point":1:{s:1:"x";i:1;}"#)
        #expect(CellDisplayFormatter.format(.bytes(BinaryFixture.data("0000000211")), columnType: blob, displayFormat: .igbinary)
            == "0x0000000211")

        let schemaID = try AvroSchemaLibrary.shared.register(
            text: #"{"type":"record","name":"R","fields":[{"name":"id","type":"long"}]}"#,
            name: "r.avsc"
        )
        let avro = ValueDisplayFormat.avro(schemaID: schemaID)
        #expect(avro.displayName.contains("r.avsc"))
        #expect(CellDisplayFormatter.format(.bytes(BinaryFixture.data("54")), columnType: blob, displayFormat: avro) == #"{"id":42}"#)
        #expect(CellDisplayFormatter.format(.bytes(BinaryFixture.data("80")), columnType: blob, displayFormat: avro) == "0x80")
    }

    @Test("The viewer shows igbinary in the PHP tree and Avro with its frame's schema ID")
    func igbinaryAndAvroDocuments() throws {
        let igbinary = BinaryValueDecoding.document(BinaryFixture.data("000000020607"), format: .igbinary)
        guard case .decoded(.php, let text, nil) = igbinary else {
            Issue.record("expected a decoded PHP tree")
            return
        }
        #expect(text == "i:7;")

        let schemaID = try AvroSchemaLibrary.shared.register(text: #"{"type":"array","items":"int"}"#, name: "ints.avsc")
        let framed = BinaryValueDecoding.document(BinaryFixture.data("000000002a020200"), format: .avro(schemaID: schemaID))
        guard case .decoded(.json, _, let note) = framed else {
            Issue.record("expected a decoded JSON tree")
            return
        }
        #expect(note?.contains("42") == true)
    }

    @Test("An Avro column whose schema is gone says so")
    func avroSchemaMissing() {
        let document = BinaryValueDecoding.document(Data([0x02]), format: .avro(schemaID: "0000000000000000"))
        guard case .failed(let error) = document else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.kind == .schemaMissing)
    }
}
