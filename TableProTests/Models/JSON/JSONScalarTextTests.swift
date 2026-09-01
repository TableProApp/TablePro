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

    /// Copy Value puts the value on the pasteboard, so it carries every byte and no quotes. Both
    /// were wrong: the clipboard used to receive the truncated hex with the printed quotes still
    /// wrapped around it, which round-trips as neither the blob nor valid JSON.
    @Test("Copy Value carries the whole blob, unquoted")
    func unquotedBlobIsComplete() {
        let copied = JSONScalarText.unquoted(.binary(sample))
        #expect(copied.hasPrefix("0x"))
        #expect(!copied.contains("\""))
        #expect(!copied.contains("…"))
        #expect(copied.count == 2 + sample.count * 2)
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
