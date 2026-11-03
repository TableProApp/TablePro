import Foundation
@testable import TableProModels
@testable import TableProPluginKit
@testable import TableProQuery
import Testing

// D1 refuses a LIKE or GLOB pattern over 50 bytes; measured on sqlite3 with the same limit, a 51-byte pattern fails
// with "LIKE or GLOB pattern too complex".
struct FilterSQLGeneratorLikeLimitTests {
    private func dialect(limit: Int?) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit,
            caseSensitivityStyle: .collationDefined,
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: true,
            likePatternByteLimit: limit
        )
    }

    private func clause(_ value: String, op: FilterOperator, limit: Int? = 50) -> String {
        FilterSQLGenerator(dialect: dialect(limit: limit), databaseType: .cloudflareD1).generateWhereClause(
            from: [TableFilter(columnName: "note", filterOperator: op, value: value)],
            logicMode: .and,
            columns: [ColumnInfo(name: "note", typeName: "TEXT")]
        )
    }

    @Test("A contains pattern at the limit stays a LIKE, byte for byte")
    func patternAtTheLimitStaysLike() {
        let body = String(repeating: "a", count: 48)

        #expect(clause(body, op: .contains) == "WHERE \"note\" LIKE '%\(body)%' ESCAPE '!'")
    }

    @Test("A contains pattern past the limit is matched as a plain substring, case folded like D1's LIKE")
    func patternPastTheLimitUsesInstr() {
        let body = String(repeating: "a", count: 49)

        #expect(clause(body, op: .contains) == "WHERE instr(LOWER(\"note\"), LOWER('\(body)')) > 0")
    }

    @Test("Starts with and ends with past the limit match the head and the tail")
    func prefixAndSuffixPastTheLimit() {
        let body = String(repeating: "b", count: 50)

        #expect(clause(body, op: .startsWith) == "WHERE instr(LOWER(\"note\"), LOWER('\(body)')) = 1")
        #expect(clause(body, op: .endsWith) == "WHERE substr(LOWER(\"note\"), -length('\(body)')) = LOWER('\(body)')")
    }

    // A `!` escape in the literal would be searched for as text: instr('a%b', '!%') is 0.
    @Test("The substring form takes the value as written, with no LIKE escape, and still doubles a quote")
    func substringLiteralHasNoLikeEscape() {
        let padding = String(repeating: "x", count: 44)

        #expect(clause(padding + "50%_it's", op: .contains)
            == "WHERE instr(LOWER(\"note\"), LOWER('\(padding)50%_it''s')) > 0")
    }

    @Test("The limit counts bytes of UTF-8, not characters", arguments: [(24, false), (25, true)])
    func limitCountsBytes(count: Int, exceeds: Bool) {
        let result = clause(String(repeating: "é", count: count), op: .contains)

        #expect(result.contains("instr(") == exceeds)
    }

    @Test("An engine with no limit keeps a LIKE however long the value")
    func noLimitKeepsLike() {
        let body = String(repeating: "a", count: 200)

        #expect(clause(body, op: .contains, limit: nil) == "WHERE \"note\" LIKE '%\(body)%' ESCAPE '!'")
    }
}
