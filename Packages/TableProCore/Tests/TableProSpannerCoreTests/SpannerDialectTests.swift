import Foundation
import TableProGoogleCloud
import TableProSpannerCore
import Testing

@Suite("SpannerDialect")
struct SpannerDialectTests {
    @Test("The database dialect string picks the dialect")
    func fromDatabaseDialect() {
        #expect(SpannerDialect(databaseDialect: "POSTGRESQL") == .postgreSQL)
        #expect(SpannerDialect(databaseDialect: "postgresql") == .postgreSQL)
        #expect(SpannerDialect(databaseDialect: "GOOGLE_STANDARD_SQL") == .googleSQL)
        #expect(SpannerDialect(databaseDialect: "DATABASE_DIALECT_UNSPECIFIED") == .googleSQL)
        #expect(SpannerDialect(databaseDialect: nil) == .googleSQL)
    }

    @Test("Per-dialect constants")
    func constants() {
        #expect(SpannerDialect.googleSQL.defaultSchema == "")
        #expect(SpannerDialect.postgreSQL.defaultSchema == "public")
        #expect(SpannerDialect.googleSQL.textCastType == "STRING")
        #expect(SpannerDialect.postgreSQL.textCastType == "TEXT")
        #expect(SpannerDialect.googleSQL.placeholder(3) == "@p3")
        #expect(SpannerDialect.postgreSQL.placeholder(3) == "$3")
        #expect(SpannerDialect.googleSQL.placeholderLexicon == .googleSQL)
        #expect(SpannerDialect.postgreSQL.placeholderLexicon == .postgreSQL)
    }

    @Test("GoogleSQL identifiers use backticks with backslash escapes")
    func googleIdentifiers() {
        let dialect = SpannerDialect.googleSQL
        #expect(dialect.quoteIdentifier("Singers") == "`Singers`")
        #expect(dialect.quoteIdentifier("a`b") == #"`a\`b`"#)
        #expect(dialect.quoteIdentifier(#"trailing\"#) == #"`trailing\\`"#)
        #expect(dialect.quoteIdentifier("x` OR TRUE --") == #"`x\` OR TRUE --`"#)
    }

    @Test("PostgreSQL identifiers use doubled double quotes")
    func postgresIdentifiers() {
        let dialect = SpannerDialect.postgreSQL
        #expect(dialect.quoteIdentifier("singers") == "\"singers\"")
        #expect(dialect.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(dialect.quoteIdentifier(#"trailing\"#) == #""trailing\""#)
        #expect(dialect.quoteIdentifier("a`b") == "\"a`b\"")
    }

    @Test("GoogleSQL strings use backslash escapes")
    func googleStrings() {
        let dialect = SpannerDialect.googleSQL
        #expect(dialect.quotedString(#"x\' OR TRUE --"#) == #"'x\\\' OR TRUE --'"#)
        #expect(dialect.quotedString("a\nb\u{0}") == #"'a\nb\x00'"#)
        #expect(dialect.escapedStringBody("O'Brien") == #"O\'Brien"#)
    }

    @Test("PostgreSQL strings double quotes, keep backslashes and drop NUL")
    func postgresStrings() {
        let dialect = SpannerDialect.postgreSQL
        #expect(dialect.quotedString(#"O'Brien\"#) == #"'O''Brien\'"#)
        #expect(dialect.quotedString(#"x\' OR TRUE --"#) == #"'x\'' OR TRUE --'"#)
        #expect(dialect.quotedString("a\u{0}b") == "'ab'")
        #expect(dialect.quotedString("a\nb") == "'a\nb'")
        #expect(dialect.escapedStringBody("it's") == "it''s")
    }

    @Test("The default schema is written unqualified")
    func qualifiedNames() {
        #expect(SpannerDialect.googleSQL.qualifiedName(schema: "", name: "Singers") == "`Singers`")
        #expect(SpannerDialect.googleSQL.qualifiedName(schema: "sales", name: "Orders") == "`sales`.`Orders`")
        #expect(SpannerDialect.postgreSQL.qualifiedName(schema: "", name: "singers") == "\"singers\"")
        #expect(SpannerDialect.postgreSQL.qualifiedName(schema: "public", name: "singers") == "\"singers\"")
        #expect(SpannerDialect.postgreSQL.qualifiedName(schema: "sales", name: "orders") == "\"sales\".\"orders\"")
    }

    @Test("System schemas match case-insensitively")
    func systemSchemas() {
        for dialect in [SpannerDialect.googleSQL, .postgreSQL] {
            #expect(dialect.isSystemSchema("INFORMATION_SCHEMA"))
            #expect(dialect.isSystemSchema("information_schema"))
            #expect(dialect.isSystemSchema("SPANNER_SYS"))
            #expect(dialect.isSystemSchema("spanner_sys"))
            #expect(dialect.isSystemSchema("pg_catalog"))
            #expect(!dialect.isSystemSchema(""))
            #expect(!dialect.isSystemSchema("public"))
            #expect(!dialect.isSystemSchema("sales"))
        }
    }

    @Test("The dialect round-trips through Codable")
    func codable() throws {
        let data = try JSONEncoder().encode(SpannerDialect.postgreSQL)
        #expect(try JSONDecoder().decode(SpannerDialect.self, from: data) == .postgreSQL)
    }
}
