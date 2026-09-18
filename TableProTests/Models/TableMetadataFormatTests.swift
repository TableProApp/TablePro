//
//  TableMetadataFormatTests.swift
//  TableProTests
//
//  `formatSize` is the only thing that writes the Table Info pane's sizes, and its placeholder is a
//  user-facing string that nothing asserted.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Table metadata formatting")
struct TableMetadataFormatTests {
    /// The repo bans em dashes in user-facing strings, and this placeholder was one. A hyphen is
    /// what a size the database did not report shows now.
    @Test("An unreported size is a hyphen, never an em dash")
    func unknownSizeIsAHyphen() {
        let placeholder = TableMetadata.formatSize(nil)
        #expect(placeholder == "-")
        #expect(!placeholder.contains("\u{2014}"))
    }

    @Test("Zero is reported as zero rather than as unknown")
    func zeroIsNotUnknown() {
        #expect(TableMetadata.formatSize(0) == "0 B")
    }

    @Test("Bytes stay bytes and larger sizes take a unit")
    func sizesCarryTheirUnit() {
        #expect(TableMetadata.formatSize(512) == "512 B")
        #expect(TableMetadata.formatSize(1_024).hasSuffix("KB"))
        #expect(TableMetadata.formatSize(1_048_576).hasSuffix("MB"))
    }
}
