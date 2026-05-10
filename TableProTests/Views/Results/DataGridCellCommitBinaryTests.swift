//
//  DataGridCellCommitBinaryTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cell commit - typed binary writes survive delegate notification")
@MainActor
struct DataGridCellCommitBinaryTests {
    @Test("PluginCellValue.fromOptional(.bytes.asText) lossily becomes .null")
    func fromOptionalBytesAsTextIsNull() {
        let bytes = Data([0xDE, 0xAD])
        let cell: PluginCellValue = .bytes(bytes)
        let viaText = PluginCellValue.fromOptional(cell.asText)
        #expect(viaText == .null,
                "Lossy: .bytes.asText is nil, then fromOptional(nil) is .null. Proves why the delegate-callback path must not re-write the cell from a String? value.")
    }

    @Test("PluginCellValue.fromOptional(.bytes.asText) for high bytes is .null, not .text")
    func highBytesViaTextIsNull() {
        let bytes = Data([0xD3, 0x8C, 0xE5, 0x66])
        let viaText = PluginCellValue.fromOptional(PluginCellValue.bytes(bytes).asText)
        #expect(viaText == .null)
        #expect(viaText.asBytes == nil)
    }
}
