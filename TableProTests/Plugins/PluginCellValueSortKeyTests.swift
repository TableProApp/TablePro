//
//  PluginCellValueSortKeyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginCellValue - sortKey")
struct PluginCellValueSortKeyTests {
    @Test(".null sortKey is empty string")
    func nullSortKey() {
        #expect(PluginCellValue.null.sortKey == "")
    }

    @Test(".text sortKey is the text verbatim")
    func textSortKey() {
        #expect(PluginCellValue.text("hello").sortKey == "hello")
        #expect(PluginCellValue.text("").sortKey == "")
    }

    @Test(".bytes sortKey is uppercase hex without 0x prefix")
    func bytesSortKey() {
        #expect(PluginCellValue.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])).sortKey == "DEADBEEF")
        #expect(PluginCellValue.bytes(Data()).sortKey == "")
        #expect(PluginCellValue.bytes(Data([0x00, 0xFF])).sortKey == "00FF")
    }

    @Test("Distinct binary values produce distinct sort keys (deterministic order)")
    func distinctBytesProduceDistinctKeys() {
        let a = PluginCellValue.bytes(Data([0x00])).sortKey
        let b = PluginCellValue.bytes(Data([0x01])).sortKey
        let c = PluginCellValue.bytes(Data([0xFF])).sortKey
        #expect(a < b)
        #expect(b < c)
        #expect(a != b)
    }

    // MARK: - asText contract
    //
    // `asText` MUST return nil for `.bytes` so callers cannot accidentally treat
    // binary cells as editable text. Returning empty string instead would cause
    // the inline cell editor to display the empty field on click and commit ""
    // on focus-out, silently wiping the original bytes (regression for #1217).

    @Test(".text.asText returns the text verbatim")
    func textAsText() {
        #expect(PluginCellValue.text("hello").asText == "hello")
        #expect(PluginCellValue.text("").asText == "")
    }

    @Test(".bytes.asText returns nil so inline edit is gated")
    func bytesAsTextIsNil() {
        #expect(PluginCellValue.bytes(Data([0xDE, 0xAD])).asText == nil)
        #expect(PluginCellValue.bytes(Data()).asText == nil)
    }

    @Test(".null.asText returns nil")
    func nullAsText() {
        #expect(PluginCellValue.null.asText == nil)
    }

    // MARK: - asBytes contract

    @Test(".bytes.asBytes returns the data; other cases return nil")
    func asBytes() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(PluginCellValue.bytes(data).asBytes == data)
        #expect(PluginCellValue.text("hello").asBytes == nil)
        #expect(PluginCellValue.null.asBytes == nil)
    }
}
