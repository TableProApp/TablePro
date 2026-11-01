import Foundation
import TableProModels
import Testing
@testable import TableProMobile

struct SQLBuilderIdentifierQuotingTests {
    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    @Test("A closing quote a combining mark follows is still doubled", arguments: ["\u{301}", "\u{FF9E}"])
    func closingQuoteBeforeCombiningMark(mark: String) {
        #expect(Self.scalars(SQLBuilder.quoteIdentifier("t]\(mark)x", for: .mssql)) == Self.scalars("[t]]\(mark)x]"))
        #expect(Self.scalars(SQLBuilder.quoteIdentifier("t\"\(mark)x", for: .postgresql)) == Self.scalars("\"t\"\"\(mark)x\""))
        #expect(Self.scalars(SQLBuilder.quoteIdentifier("t`\(mark)x", for: .mysql)) == Self.scalars("`t``\(mark)x`"))
        #expect(Self.scalars(SQLBuilder.quoteIdentifier("t\"\(mark)x", for: .sqlite)) == Self.scalars("\"t\"\"\(mark)x\""))
    }

    @Test("Opening a crafted PostgreSQL table sends one statement")
    func browseOfCraftedTableIsOneIdentifier() {
        let sql = SQLBuilder.buildSelect(
            table: "t\"\u{301}; ALTER ROLE mallory SUPERUSER; --", schema: "public", type: .postgresql, limit: 200, offset: 0
        )
        #expect(Self.scalars(sql).starts(with: Self.scalars("SELECT * FROM \"public\".\"t\"\"\u{301}; ALTER ROLE mallory SUPERUSER; --\"")))
    }
}
