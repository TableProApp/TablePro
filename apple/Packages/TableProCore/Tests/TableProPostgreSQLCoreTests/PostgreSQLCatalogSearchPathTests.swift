import Foundation
import Testing

@testable import TableProPostgreSQLCore

struct PostgreSQLCatalogSearchPathTests {
    @Test("A catalog read resolves functions and operators in pg_catalog alone, with temporary relations last")
    func pinnedPathIsPgCatalogThenPgTemp() {
        #expect(PostgreSQLCatalogSearchPath.pinned == "SET LOCAL search_path = pg_catalog, pg_temp; ")
    }

    @Test("A schema-relative read keeps pg_catalog first and pg_temp last, with the schema quoted")
    func relativePathQuotesTheSchema() {
        #expect(
            PostgreSQLCatalogSearchPath.relative(to: "sales")
                == "SET LOCAL search_path = pg_catalog, \"sales\", pg_temp; "
        )
        #expect(
            PostgreSQLCatalogSearchPath.relative(to: "Weird \"Schema\"")
                == "SET LOCAL search_path = pg_catalog, \"Weird \"\"Schema\"\"\", pg_temp; "
        )
    }

    @Test("A quote followed by a combining mark is still doubled")
    func quoteBeforeCombiningMarkIsDoubled() {
        #expect(
            PostgreSQLCatalogSearchPath.relative(to: "a\"\u{0301}b")
                == "SET LOCAL search_path = pg_catalog, \"a\"\"\u{0301}b\", pg_temp; "
        )
    }
}
