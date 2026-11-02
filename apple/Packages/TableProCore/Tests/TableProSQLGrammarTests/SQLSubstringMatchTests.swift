import Foundation
import TableProSQLGrammar
import Testing

struct SQLSubstringMatchTests {
    @Test("Each test folds both sides with the function it is given")
    func forms() {
        #expect(SQLSubstringMatch.contains("\"name\"", literal: "'ab'", fold: "LOWER") == "instr(LOWER(\"name\"), LOWER('ab')) > 0")
        #expect(SQLSubstringMatch.notContains("\"name\"", literal: "'ab'", fold: "LOWER") == "instr(LOWER(\"name\"), LOWER('ab')) = 0")
        #expect(SQLSubstringMatch.startsWith("\"name\"", literal: "'ab'", fold: "LOWER") == "instr(LOWER(\"name\"), LOWER('ab')) = 1")
        #expect(SQLSubstringMatch.contains("c", literal: "'x'", fold: "UPPER") == "instr(UPPER(c), UPPER('x')) > 0")
    }

    @Test("Ends with compares the tail, never the position of the first match")
    func endsWithComparesTheTail() {
        let condition = SQLSubstringMatch.endsWith("\"name\"", literal: "'ab'", fold: "LOWER")
        #expect(condition == "substr(LOWER(\"name\"), -length('ab')) = LOWER('ab')")
        #expect(!condition.contains("instr"))
    }

    @Test("The literal goes in as given, so a percent or underscore stays a plain character")
    func literalIsNotAPattern() {
        #expect(
            SQLSubstringMatch.contains("c", literal: "'50%_''s'", fold: "LOWER")
                == "instr(LOWER(c), LOWER('50%_''s')) > 0"
        )
    }

    @Test("A pattern exceeds the limit only past it, counting the wildcards", arguments: [
        (String(repeating: "a", count: 48), 2, 50, false),
        (String(repeating: "a", count: 49), 2, 50, true),
        (String(repeating: "a", count: 49), 1, 50, false),
        (String(repeating: "a", count: 50), 1, 50, true),
    ])
    func exceedsCountsWildcards(body: String, wildcards: Int, limit: Int, expected: Bool) {
        #expect(SQLSubstringMatch.exceeds(body, wildcards: wildcards, limit: limit) == expected)
    }

    @Test("The limit is in bytes of UTF-8, not characters")
    func exceedsCountsBytes() {
        #expect(!SQLSubstringMatch.exceeds(String(repeating: "é", count: 24), wildcards: 2, limit: 50))
        #expect(SQLSubstringMatch.exceeds(String(repeating: "é", count: 25), wildcards: 2, limit: 50))
    }

    @Test("No limit never exceeds")
    func noLimit() {
        #expect(!SQLSubstringMatch.exceeds(String(repeating: "a", count: 10_000), wildcards: 2, limit: nil))
    }
}
