import Testing
@testable import TableProQuery
@testable import TableProModels

@Suite("SQLDialectFactory Tests")
struct SQLDialectFactoryTests {
    @Test("Factory returns dialect-specific identifier quotes")
    func dialectSpecificIdentifierQuotes() {
        #expect(SQLDialectFactory.quoteIdentifier("users", for: .mysql) == "`users`")
        #expect(SQLDialectFactory.quoteIdentifier("users", for: .postgresql) == "\"users\"")
        #expect(SQLDialectFactory.quoteIdentifier("users", for: .mssql) == "[users]")
    }

    @Test("MSSQL identifier quoting escapes closing brackets")
    func mssqlIdentifierEscapesClosingBracket() {
        #expect(SQLDialectFactory.quoteIdentifier("name]part", for: .mssql) == "[name]]part]")
    }

    @Test("Descriptor defaults bracket closing quote")
    func descriptorDefaultsBracketClosingQuote() {
        let descriptor = QueryDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: []
        )
        #expect(descriptor.identifierClosingQuote == "]")
        #expect(descriptor.quoteIdentifier("name]part") == "[name]]part]")
    }

    @Test("Descriptor builds SQL literals with optional special literal interpretation")
    func descriptorSQLLiterals() {
        let descriptor = SQLDialectFactory.dialect(for: .mysql)
        #expect(descriptor.sqlLiteral(for: "123") == "123")
        #expect(descriptor.sqlLiteral(for: "NULL") == "NULL")
        #expect(descriptor.sqlLiteral(for: "TRUE") == "1")
        #expect(descriptor.sqlLiteral(for: "O'Brien") == "'O''Brien'")
        #expect(descriptor.sqlLiteral(for: "NULL", interpretSpecialLiterals: false) == "'NULL'")
    }

    @Test("Factory exposes pagination style by database type")
    func paginationStyleByDatabaseType() {
        #expect(SQLDialectFactory.dialect(for: .mssql).paginationStyle == .offsetFetch)
        #expect(SQLDialectFactory.dialect(for: .oracle).paginationStyle == .offsetFetch)
        #expect(SQLDialectFactory.dialect(for: .postgresql).paginationStyle == .limit)
    }
}
