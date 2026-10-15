//
//  QueryContainerRebindingTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct QueryContainerRebindingTests {
    private func context(database: String, schema: String?) -> TabTableContext {
        var context = TabTableContext()
        context.databaseName = database
        context.schemaName = schema
        return context
    }

    @Test("Another database drops the schema that belonged to the old one")
    func databaseRebindDropsTheSchema() {
        var bound = context(database: "db1", schema: "sales")

        QueryContainerRebinding.rebind(&bound, to: "db2", target: .database)

        #expect(bound.databaseName == "db2")
        #expect(bound.schemaName == nil)
    }

    @Test("Another schema keeps the database")
    func schemaRebindKeepsTheDatabase() {
        var bound = context(database: "ORCL", schema: "HR")

        QueryContainerRebinding.rebind(&bound, to: "SCOTT", target: .schema)

        #expect(bound.databaseName == "ORCL")
        #expect(bound.schemaName == "SCOTT")
    }
}
