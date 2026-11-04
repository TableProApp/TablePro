import CSQLite
import Foundation
import TableProSQLGrammar
import TableProSQLQuoting
import Testing

// Seeded, so a failure names an input that reproduces.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private let hostileScalars: [Unicode.Scalar] = [
    "'", "\"", "`", "[", "]", "\\", "\n", "\r", "\t", ";", "-", "/", "*", "$", "?", "#", " ", "a", "Z", "0",
    "\u{301}", "\u{200C}", "\u{200D}", "\u{FE0F}", "\u{FF9E}", "\u{1F3FB}", "\u{E9}", "\u{1A}", "\u{08}",
    "\u{2028}", "\u{85}",
]

private func hostileStrings(count: Int, seed: UInt64) -> [String] {
    var generator = SplitMix64(seed: seed)
    return (0..<count).map { _ in
        var scalars = String.UnicodeScalarView()
        for _ in 0..<Int.random(in: 1...14, using: &generator) {
            scalars.append(hostileScalars.randomElement(using: &generator) ?? "a")
        }
        return String(scalars)
    }
}

struct SQLQuotingRoundTripTests {
    @Test("SQLite reads every quoted literal and name back as the input, in one statement")
    func sqliteRoundTrip() throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(":memory:", &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        for value in hostileStrings(count: 600, seed: 0x5EED_B3) {
            let sql = "SELECT \(SQLQuoting.stringLiteral(value)) AS \(SQLQuoting.identifier(value))"
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let prepared = sql.withCString { sqlite3_prepare_v2(database, $0, -1, &statement, &tail) }
            defer { sqlite3_finalize(statement) }
            try #require(prepared == SQLITE_OK, "\(sql.debugDescription)")
            #expect(tail.map { String(cString: $0) } == "", "\(sql.debugDescription)")
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            let text = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let name = sqlite3_column_name(statement, 0).map { String(cString: $0) }
            #expect(text == value, "\(sql.debugDescription)")
            #expect(name == value, "\(sql.debugDescription)")
        }
    }

    @Test("Every curated grammar reads a quoted literal as one token that ends where it was written")
    func literalIsOneTokenInEveryReading() {
        let values = hostileStrings(count: 300, seed: 0xB3_11)
        for typeId in SQLLexicalProfile.curatedDatabaseTypeIds.sorted() {
            guard let profile = SQLLexicalProfile.curated(forDatabaseTypeId: typeId) else { continue }
            for reading in profile.readings {
                for value in values {
                    let literal = SQLQuoting.stringLiteral(value, escapes: reading.stringEscapes)
                    #expect(spansWholeText(literal, grammar: reading), "\(typeId) \(literal.debugDescription)")
                }
            }
        }
    }

    @Test("Every curated grammar reads a quoted name as one token that ends where it was written")
    func identifierIsOneTokenInEveryReading() {
        let values = hostileStrings(count: 300, seed: 0xB3_22)
        for typeId in SQLLexicalProfile.curatedDatabaseTypeIds.sorted() {
            guard let profile = SQLLexicalProfile.curated(forDatabaseTypeId: typeId) else { continue }
            for reading in profile.readings {
                for quote in quotes(in: reading) {
                    for value in values {
                        let name = SQLQuoting.identifier(
                            value,
                            quote: quote,
                            backslashEscapes: reading.backslashEscapes(in: quote)
                        )
                        #expect(spansWholeText(name, grammar: reading), "\(typeId) \(name.debugDescription)")
                    }
                }
            }
        }
    }

    @Test("A literal written without the session's answer ends where it was written under every reading")
    func literalHoldsUnderEveryReadingWithoutASession() {
        let values = hostileStrings(count: 200, seed: 0xB3_44)
        for typeId in SQLLexicalProfile.curatedDatabaseTypeIds.sorted() {
            guard let profile = SQLLexicalProfile.curated(forDatabaseTypeId: typeId) else { continue }
            // GoogleSQL beside Spanner's PostgreSQL dialect has no spelling both read: the session has to settle it.
            guard !profile.readings.contains(where: { $0.contains(.tripleQuotedStrings) }) else { continue }
            let escapes = SQLLexicalReadings.stringEscapes(databaseTypeId: typeId, declared: nil, session: nil)
            for value in values {
                let literal = SQLQuoting.stringLiteral(value, escapes: escapes)
                for reading in profile.readings {
                    #expect(spansWholeText(literal, grammar: reading), "\(typeId) \(literal.debugDescription)")
                }
            }
        }
    }

    @Test("A written literal decodes back to its value, and anything else decodes to nothing")
    func decodeRoundTrip() {
        for value in hostileStrings(count: 400, seed: 0xB3_33) {
            for escapes in [SQLStringEscapes.standard, .backslash, .mysql, .googleSQL, .sqlServer] {
                let literal = SQLQuoting.stringLiteral(value, escapes: escapes)
                #expect(SQLQuoting.decodedStringLiteral(literal, escapes: escapes) == value, "\(literal.debugDescription)")
            }
        }
        for text in ["'a'b'", "'a", "a'", "'a' || 'b'", "'", "x", "'O''\u{301}Neil'x"] {
            #expect(SQLQuoting.decodedStringLiteral(text) == nil, "\(text.debugDescription)")
        }
        #expect(SQLQuoting.decodedStringLiteral("'O''\u{301}Neil'") == "O'\u{301}Neil")
    }

    private func quotes(in grammar: SQLLexicalGrammar) -> [SQLIdentifierQuote] {
        var quotes: [SQLIdentifierQuote] = [.doubleQuote]
        if grammar.contains(.backtickQuotes) { quotes.append(.backtick) }
        // SQLite reads `[a]` with no escape for `]`, so a bracket only quotes where `]]` stands for one.
        if grammar.contains(.doubledClosingBracketEscapes) { quotes.append(.bracket) }
        return quotes
    }

    private func spansWholeText(_ text: String, grammar: SQLLexicalGrammar) -> Bool {
        let source = text as NSString
        guard let span = SQLNonCodeSpan.span(at: 0, in: source, grammar: grammar) else { return false }
        return span.kind == .quoted && span.isTerminated && span.end == source.length
    }
    @Test("SQL Server keeps continuation bytes and only removes NUL")
    func sqlServerLineEndings() {
        for newline in ["\n", "\r\n", "\r", "\r\r\n", "\r\\\n", "\n\r"] {
            for count in 1...4 {
                let value = "日本'\u{301}" + String(repeating: "\\", count: count) + newline + "'; SELECT 1; --"
                let literal = SQLQuoting.stringLiteral(value, escapes: .sqlServer)
                #expect(SQLQuoting.decodedStringLiteral(literal, escapes: .sqlServer) == value)
                #expect(!SQLStringEscapes.sqlServer.backslashEscapes)
            }
        }
        let literal = SQLQuoting.stringLiteral("x\\\0\n", escapes: .sqlServer)
        #expect(literal == "'x\\\\\n\n'")
        #expect(SQLQuoting.decodedStringLiteral(literal, escapes: .sqlServer) == "x\\\n")
        #expect(SQLQuoting.decodedStringLiteral("'a\\\nb'", escapes: .sqlServer) == "ab")
        #expect(SQLQuoting.decodedStringLiteral("'a\\\r\nb'", escapes: .sqlServer) == "ab")
        #expect(SQLQuoting.decodedStringLiteral("'a\\\rb'", escapes: .sqlServer) == "a\rb")
    }
}
