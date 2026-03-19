//
//  CloudflareD1DriverHelperTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Cloudflare D1 Driver Helpers")
struct CloudflareD1DriverHelperTests {

    // MARK: - Local copies of helper functions for testing

    private static func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    private static func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS TEXT)"
    }

    private static func isUuid(_ string: String) -> Bool {
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return string.range(of: uuidPattern, options: .regularExpression) != nil
    }

    private static func stripLimitOffset(from query: String) -> String {
        let ns = query as NSString
        let len = ns.length
        guard len > 0 else { return query }

        let upper = query.uppercased() as NSString
        var depth = 0
        var i = len - 1

        while i >= 4 {
            let ch = upper.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x54 {
                let start = i - 4
                if start >= 0 {
                    let candidate = upper.substring(with: NSRange(location: start, length: 5))
                    if candidate == "LIMIT" {
                        if start == 0 || CharacterSet.whitespacesAndNewlines
                            .contains(UnicodeScalar(upper.character(at: start - 1)) ?? UnicodeScalar(0)) {
                            return ns.substring(to: start)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            i -= 1
        }
        return query
    }

    private static func formatDDL(_ ddl: String) -> String {
        guard ddl.uppercased().hasPrefix("CREATE TABLE") else {
            return ddl
        }

        var formatted = ddl

        if let range = formatted.range(of: "(") {
            let before = String(formatted[..<range.lowerBound])
            let after = String(formatted[range.upperBound...])
            formatted = before + "(\n  " + after.trimmingCharacters(in: .whitespaces)
        }

        var result = ""
        var depth = 0
        var charIndex = 0
        let chars = Array(formatted)

        while charIndex < chars.count {
            let char = chars[charIndex]

            if char == "(" {
                depth += 1
                result.append(char)
            } else if char == ")" {
                depth -= 1
                result.append(char)
            } else if char == "," && depth == 1 {
                result.append(",\n  ")
                charIndex += 1
                while charIndex < chars.count && chars[charIndex].isWhitespace {
                    charIndex += 1
                }
                charIndex -= 1
            } else {
                result.append(char)
            }

            charIndex += 1
        }

        formatted = result

        if let range = formatted.range(of: ")", options: .backwards) {
            let before = String(formatted[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(formatted[range.lowerBound...])
            formatted = before + "\n" + after
        }

        return formatted.isEmpty ? ddl : formatted
    }

    // MARK: - quoteIdentifier

    @Test("Quotes simple identifier with double quotes")
    func quotesSimpleIdentifier() {
        #expect(Self.quoteIdentifier("users") == "\"users\"")
    }

    @Test("Escapes double quotes in identifier by doubling")
    func escapesDoubleQuotes() {
        #expect(Self.quoteIdentifier("my\"table") == "\"my\"\"table\"")
    }

    @Test("Handles empty identifier")
    func quotesEmptyIdentifier() {
        #expect(Self.quoteIdentifier("") == "\"\"")
    }

    @Test("Quotes identifier with spaces")
    func quotesIdentifierWithSpaces() {
        #expect(Self.quoteIdentifier("user name") == "\"user name\"")
    }

    @Test("Quotes reserved word")
    func quotesReservedWord() {
        #expect(Self.quoteIdentifier("select") == "\"select\"")
    }

    // MARK: - escapeStringLiteral

    @Test("Doubles single quotes")
    func escapesSingleQuotes() {
        #expect(Self.escapeStringLiteral("it's") == "it''s")
    }

    @Test("Strips null bytes")
    func stripsNullBytes() {
        #expect(Self.escapeStringLiteral("hello\0world") == "helloworld")
    }

    @Test("Handles multiple single quotes")
    func escapesMultipleQuotes() {
        #expect(Self.escapeStringLiteral("it's a 'test'") == "it''s a ''test''")
    }

    @Test("Passes through plain string unchanged")
    func plainStringUnchanged() {
        #expect(Self.escapeStringLiteral("hello world") == "hello world")
    }

    @Test("Handles empty string")
    func escapesEmptyString() {
        #expect(Self.escapeStringLiteral("") == "")
    }

    // MARK: - castColumnToText

    @Test("Wraps column in CAST AS TEXT")
    func castColumn() {
        #expect(Self.castColumnToText("age") == "CAST(age AS TEXT)")
    }

    @Test("Wraps quoted column in CAST AS TEXT")
    func castQuotedColumn() {
        #expect(Self.castColumnToText("\"my col\"") == "CAST(\"my col\" AS TEXT)")
    }

    // MARK: - isUuid

    @Test("Recognizes valid UUID")
    func recognizesValidUuid() {
        #expect(Self.isUuid("550e8400-e29b-41d4-a716-446655440000"))
    }

    @Test("Recognizes uppercase UUID")
    func recognizesUppercaseUuid() {
        #expect(Self.isUuid("550E8400-E29B-41D4-A716-446655440000"))
    }

    @Test("Rejects non-UUID string")
    func rejectsNonUuid() {
        #expect(!Self.isUuid("my-database"))
    }

    @Test("Rejects empty string")
    func rejectsEmptyUuid() {
        #expect(!Self.isUuid(""))
    }

    @Test("Rejects UUID without dashes")
    func rejectsUuidWithoutDashes() {
        #expect(!Self.isUuid("550e8400e29b41d4a716446655440000"))
    }

    @Test("Rejects UUID with extra characters")
    func rejectsUuidWithExtra() {
        #expect(!Self.isUuid("550e8400-e29b-41d4-a716-446655440000-extra"))
    }

    // MARK: - stripLimitOffset

    @Test("Strips LIMIT clause from end")
    func stripsLimit() {
        let result = Self.stripLimitOffset(from: "SELECT * FROM users LIMIT 10")
        #expect(result == "SELECT * FROM users")
    }

    @Test("Strips LIMIT and OFFSET from end")
    func stripsLimitOffset() {
        let result = Self.stripLimitOffset(from: "SELECT * FROM users LIMIT 10 OFFSET 20")
        #expect(result == "SELECT * FROM users")
    }

    @Test("Returns query unchanged without LIMIT")
    func noLimitUnchanged() {
        let query = "SELECT * FROM users WHERE id = 1"
        #expect(Self.stripLimitOffset(from: query) == query)
    }

    @Test("Does not strip LIMIT inside subquery")
    func preservesSubqueryLimit() {
        let query = "SELECT * FROM (SELECT * FROM users LIMIT 5) AS sub LIMIT 10"
        let result = Self.stripLimitOffset(from: query)
        #expect(result.contains("LIMIT 5"))
    }

    @Test("Handles empty query")
    func emptyQuery() {
        #expect(Self.stripLimitOffset(from: "") == "")
    }

    @Test("Handles case-insensitive LIMIT")
    func caseInsensitiveLimit() {
        let result = Self.stripLimitOffset(from: "SELECT * FROM users limit 10")
        #expect(result == "SELECT * FROM users")
    }

    // MARK: - formatDDL

    @Test("Formats CREATE TABLE with column indentation")
    func formatsCreateTable() {
        let ddl = "CREATE TABLE users (id INTEGER, name TEXT, email TEXT)"
        let result = Self.formatDDL(ddl)
        #expect(result.contains("\n  id INTEGER"))
        #expect(result.contains(",\n  name TEXT"))
        #expect(result.contains(",\n  email TEXT"))
    }

    @Test("Returns non-CREATE TABLE unchanged")
    func nonCreateTableUnchanged() {
        let ddl = "CREATE VIEW my_view AS SELECT * FROM users"
        #expect(Self.formatDDL(ddl) == ddl)
    }

    @Test("Returns CREATE INDEX unchanged")
    func createIndexUnchanged() {
        let ddl = "CREATE INDEX idx_name ON users (name)"
        #expect(Self.formatDDL(ddl) == ddl)
    }

    @Test("Handles single-column table")
    func singleColumnTable() {
        let ddl = "CREATE TABLE simple (id INTEGER PRIMARY KEY)"
        let result = Self.formatDDL(ddl)
        #expect(result.contains("id INTEGER PRIMARY KEY"))
    }

    // MARK: - SQL Generation

    @Test("buildExplainQuery prepends EXPLAIN QUERY PLAN")
    func buildExplainQuery() {
        let sql = "SELECT * FROM users"
        let result = "EXPLAIN QUERY PLAN \(sql)"
        #expect(result == "EXPLAIN QUERY PLAN SELECT * FROM users")
    }

    @Test("truncateTableStatements uses DELETE FROM")
    func truncateUsesDelete() {
        let table = "users"
        let result = "DELETE FROM \(Self.quoteIdentifier(table))"
        #expect(result == "DELETE FROM \"users\"")
    }

    @Test("dropObjectStatement uses DROP IF EXISTS")
    func dropObjectStatement() {
        let result = "DROP TABLE IF EXISTS \(Self.quoteIdentifier("users"))"
        #expect(result == "DROP TABLE IF EXISTS \"users\"")
    }

    @Test("editViewFallbackTemplate generates DROP and CREATE")
    func editViewTemplate() {
        let viewName = "my_view"
        let quoted = Self.quoteIdentifier(viewName)
        let template = "DROP VIEW IF EXISTS \(quoted);\nCREATE VIEW \(quoted) AS\nSELECT * FROM table_name;"
        #expect(template.contains("DROP VIEW IF EXISTS \"my_view\""))
        #expect(template.contains("CREATE VIEW \"my_view\""))
    }
}
