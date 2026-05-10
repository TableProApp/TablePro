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
}
