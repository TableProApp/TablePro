//
//  JSONScalarTextTests.swift
//  TableProTests
//
//  What a printed line carries and what Copy Value carries are not the same thing for a blob.
//

import Foundation
import Testing

@testable import TablePro

@Suite("JSONScalarText")
struct JSONScalarTextTests {
    private let sample = Data((0..<200).map { UInt8($0 % 256) })

    @Test("A printed blob is quoted and stops at the display cap")
    func printedBlobIsCapped() {
        let printed = JSONScalarText.printed(.binary(sample))
        #expect(printed.hasPrefix("\"0x"))
        #expect(printed.hasSuffix("…\""))
        #expect(printed.contains("0x000102"))
    }

    /// The quotes were the bug, not the cap. Copy Value used to hand the pasteboard the printed
    /// form, quotes included, which round-trips as neither the blob nor valid JSON; the 64-byte cap
    /// is what `RowValueCopyFormatter` already gives the grid's own Copy for the same cell.
    @Test("Copy Value gives unquoted hex, capped the way the grid's own Copy is")
    func unquotedBlobIsUnquotedAndCapped() {
        let copied = JSONScalarText.unquoted(.binary(sample))
        #expect(copied.hasPrefix("0x"))
        #expect(!copied.contains("\""))
        #expect(copied.hasSuffix("…"))
        #expect(copied.count == 2 + JSONScalarText.maxDisplayedHexBytes * 2 + 1)
    }

    @Test("A blob within the cap copies whole")
    func shortBlobCopiesWhole() {
        #expect(JSONScalarText.unquoted(.binary(Data([0x4C, 0x65]))) == "0x4C65")
    }

    @Test("A blob shorter than the cap prints without an ellipsis")
    func shortBlobIsNotMarkedTruncated() {
        let printed = JSONScalarText.printed(.binary(Data([0x4C, 0x65])))
        #expect(printed == "\"0x4C65\"")
    }

    @Test("An empty blob prints as an empty hex value rather than as an empty string")
    func emptyBlob() {
        #expect(JSONScalarText.unquoted(.binary(Data())) == "0x")
    }

    @Test("A string is escaped when printed and raw when copied")
    func stringEscaping() {
        #expect(JSONScalarText.printed(.string("a\"b\nc")) == "\"a\\\"b\\nc\"")
        #expect(JSONScalarText.unquoted(.string("a\"b\nc")) == "a\"b\nc")
    }
}
