import Foundation
import TableProSQLGrammar
import Testing

struct DatabendStatementReadingsTests {
    private static let readings = SQLLexicalReadings.resolve(databaseTypeId: "Databend", declared: nil, session: nil)

    private static func tier(_ sql: String) -> StatementTier {
        SQLStatementClassifier.classify(sql, databaseTypeId: "Databend", readings: readings).tier
    }

    private static func deletesEveryRow(_ sql: String) -> Bool {
        SQLStatementClassifier.deletesEveryRow(sql, databaseTypeId: "Databend", readings: readings)
    }

    // Measured on 1.2.880 and 1.2.958: each text dropped the table.
    @Test("A DROP behind a hint the server skips is destructive", arguments: [
        "/*+ ' */ SELECT 1 -- ' */ DROP TABLE customers",
        "/*+ @x*/ SELECT 1 */ DROP TABLE customers",
        "/*+ $$ */ SELECT $$ */ DROP TABLE customers",
        "/*+ /*+ */ SELECT 1 */ DROP TABLE customers",
        "/*+ SET_VAR(max_threads=1) */ DROP TABLE customers",
        "/*+ @s\\' */ DROP TABLE customers -- ' */ SELECT 1",
    ])
    func dropBehindASkippedHint(sql: String) {
        #expect(Self.tier(sql) == .destructive)
    }

    // Measured on 1.2.880, which dropped the table; 1.2.958 refused both texts.
    @Test("A DROP behind a comment a release before 1.2.884 leaves open is destructive", arguments: [
        "/** x **/ SELECT 1 /* */ DROP TABLE customers",
        "/**/ SELECT 1 /* */ DROP TABLE customers",
    ])
    func dropBehindAPairedStarComment(sql: String) {
        #expect(Self.tier(sql) == .destructive)
    }

    // Measured on 1.2.958: the statement replaced table 中 and its rows.
    @Test("A keyword the server reads apart from the non-ASCII name after it still tiers the statement")
    func keywordBeforeANonASCIIName() {
        #expect(Self.tier("CREATE OR REPLACE TABLE\u{4E2D} (id INT)") == .destructive)
        #expect(Self.tier("SELECT 1 AS \u{540D}\u{524D} FROM customers") == .safe)
    }

    // Measured on 1.2.880 and 1.2.958: each text dropped the table.
    @Test("A statement under SETTINGS is tiered as itself", arguments: [
        "SETTINGS (max_threads=1) DROP TABLE customers",
        "SETTINGS DROP TABLE customers",
        "settings (max_threads = (1)) /*+ ' */ SELECT 1 -- ' */ DROP TABLE customers",
    ])
    func settingsWrapperIsTieredByItsStatement(sql: String) {
        #expect(Self.tier(sql) == .destructive)
    }

    @Test("A DELETE under SETTINGS deletes every row")
    func deleteUnderSettings() {
        #expect(Self.deletesEveryRow("SETTINGS (max_threads=1) DELETE FROM customers"))
        #expect(!Self.deletesEveryRow("SETTINGS (max_threads=1) DELETE FROM customers WHERE id = 1"))
    }

    // Measured on 1.2.880 and 1.2.958: the INSERT ran although the server could not tokenize the text after it, and on
    // 1.2.958 the REPLACE too.
    @Test("An INSERT before text the server cannot tokenize is still a write")
    func insertBeforeUntokenizableText() {
        #expect(Self.tier("/*+ ' */ SELECT 1 -- ' */ INSERT INTO customers SELECT 4 'x") == .write)
        #expect(Self.tier("/*+ ' */ SELECT 1 -- ' */ REPLACE\u{4E2D} ON (id) SELECT 4 'x") == .write)
    }

    @Test("A statement one release refuses to tokenize is read only as the releases that run it read it")
    func refusedReadingAddsNothing() {
        #expect(!Self.deletesEveryRow("DELETE FROM customers /**/ WHERE id = 1"))
        #expect(Self.tier("WITH `a``b` AS (SELECT 1) SELECT * FROM `a``b`") == .safe)
    }

    @Test("A DELETE behind a skipped hint deletes every row")
    func deleteBehindASkippedHint() {
        #expect(Self.deletesEveryRow("/*+ ' */ SELECT 1 -- ' */ DELETE FROM customers"))
        #expect(!Self.deletesEveryRow("/*+ ' */ SELECT 1 -- ' */ DELETE FROM customers WHERE id = 1"))
    }

    // Read whole, the first hint's quote runs to the second hint and hides the DROP the second statement runs.
    @Test("Each statement the app sends is read the way the server reads it alone")
    func statementsAreReadAlone() {
        #expect(Self.tier("SELECT 1 /*+ ' */; /*+ ' */ SELECT 1 -- ' */ DROP TABLE customers") == .destructive)
    }

    @Test("A statement run from a code string is read the server's way too")
    func codeStringIsReadAlike() {
        #expect(Self.tier("EXECUTE IMMEDIATE $$/*+ ' */ SELECT 1 -- ' */ DROP TABLE customers$$") == .destructive)
    }

    @Test("Hints, stage names and `$$` that hide nothing leave a query safe", arguments: [
        "SELECT /*+ SET_VAR(max_threads=1) */ * FROM customers",
        "/*+ SET_VAR(max_threads=1) */ SELECT 1",
        "SELECT 1 AS a$$, 2 -- $$",
        "SELECT * FROM @s/data/ WHERE id = 1",
        "/** note **/ SELECT 1",
        "SELECT '/*+', $$ */ DROP $$ FROM customers",
    ])
    func queriesStaySafe(sql: String) {
        #expect(Self.tier(sql) == .safe)
    }
}
