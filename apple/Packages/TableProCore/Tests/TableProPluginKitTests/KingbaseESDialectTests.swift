import TableProPluginKit
import Testing

struct KingbaseESDialectTests {
    @Test("KingbaseES keeps PostgreSQL dollar quotes and escape strings")
    func postgresLexing() {
        let dialect = SqlDialect.from(databaseTypeId: "KingbaseES")
        #expect(dialect == .postgres)
        #expect(dialect.supportsDollarQuotes)
        #expect(dialect.supportsEscapeStringPrefix)
        #expect(!dialect.requiresBackslashEscapesInSingleQuotes)
    }
}
