//
//  PostgreSQLDriverTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

// MARK: - SQL Escaping Correctness

struct PostgreSQLSQLEscapingCorrectness {

    @Test("ANSI escaping preserves backslashes")
    func backslashPreserved() {
        let input = "test\\table"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "test\\table")
    }

    @Test("ANSI escaping preserves literal newlines")
    func newlinePreserved() {
        let input = "line1\nline2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "line1\nline2")
    }

    @Test("ANSI escaping preserves literal tabs")
    func tabPreserved() {
        let input = "col1\tcol2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "col1\tcol2")
    }

    @Test("ANSI escaping doubles single quotes and preserves control chars")
    func combinedSpecialChars() {
        let input = "it's a \\path\n"
        let result = SQLEscaping.escapeStringLiteral(input)

        #expect(!result.contains("\\\\"), "ANSI escaping should not double backslashes")
        #expect(result.contains("\n"), "ANSI escaping should preserve literal newlines")
        #expect(result.contains("''"), "ANSI escaping should double single quotes")
    }
}
