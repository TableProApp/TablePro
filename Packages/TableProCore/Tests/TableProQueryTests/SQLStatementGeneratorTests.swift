import Testing
@testable import TableProQuery

@Suite("SQLStatementGenerator Tests")
struct SQLStatementGeneratorTests {
    @Test("String NULL value is preserved as text")
    func stringNullValueIsPreserved() {
        let generator = SQLStatementGenerator(dialect: SQLDialectFactory.dialect(for: .postgresql))
        let sql = generator.generateInsert(table: "users", columns: ["name"], values: ["NULL"])
        #expect(sql == "INSERT INTO \"users\" (\"name\") VALUES ('NULL')")
    }

    @Test("Nil value is SQL NULL")
    func nilValueIsSQLNull() {
        let generator = SQLStatementGenerator(dialect: SQLDialectFactory.dialect(for: .postgresql))
        let sql = generator.generateInsert(table: "users", columns: ["name"], values: [nil])
        #expect(sql == "INSERT INTO \"users\" (\"name\") VALUES (NULL)")
    }
}
