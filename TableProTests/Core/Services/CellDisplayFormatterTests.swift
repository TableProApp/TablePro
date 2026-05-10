//
//  CellDisplayFormatterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("CellDisplayFormatter")
@MainActor
struct CellDisplayFormatterTests {
    @Test("nil input returns nil")
    func nilInput() {
        let result = CellDisplayFormatter.format(nil, columnType: nil)
        #expect(result == nil)
    }

    @Test("empty string returns empty")
    func emptyString() {
        let result = CellDisplayFormatter.format(.text(""), columnType: nil)
        #expect(result == "")
    }

    @Test("plain text passes through unchanged")
    func plainTextPassthrough() {
        let result = CellDisplayFormatter.format(.text("hello world"), columnType: nil)
        #expect(result == "hello world")
    }

    @Test("text with linebreaks is sanitized")
    func linebreaksSanitized() {
        let result = CellDisplayFormatter.format(.text("line1\nline2\rline3"), columnType: nil)
        #expect(result == "line1 line2 line3")
    }

    @Test("text over max length is truncated")
    func longTextTruncated() {
        let longString = String(repeating: "a", count: CellDisplayFormatter.maxDisplayLength + 100)
        let result = CellDisplayFormatter.format(.text(longString), columnType: nil)
        let expected = String(repeating: "a", count: CellDisplayFormatter.maxDisplayLength) + "..."
        #expect(result == expected)
    }

    @Test("text at max length is not truncated")
    func exactMaxLengthNotTruncated() {
        let exactString = String(repeating: "b", count: CellDisplayFormatter.maxDisplayLength)
        let result = CellDisplayFormatter.format(.text(exactString), columnType: nil)
        #expect(result == exactString)
    }

    @Test("nil column type skips type-specific formatting")
    func nilColumnType() {
        let result = CellDisplayFormatter.format(.text("2024-01-01"), columnType: nil)
        #expect(result == "2024-01-01")
    }
}
