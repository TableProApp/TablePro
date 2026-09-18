import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Table Query Builder implicit schema")
struct TableQueryBuilderImplicitSchemaTests {
    private func builder(for databaseType: DatabaseType) throws -> TableQueryBuilder {
        let dialect = try #require(PluginManager.shared.sqlDialect(for: databaseType))
        return TableQueryBuilder(
            databaseType: databaseType,
            pluginDriver: nil,
            dialect: dialect,
            pagination: PluginManager.shared.paginationCapability(for: databaseType),
            dialectQuote: quoteIdentifierFromDialect(dialect)
        )
    }

    private let activeFilter = TableFilter(columnName: "status", filterOperator: .equal, value: "open")

    @Test("A table in Spanner's default schema is browsed unqualified")
    func defaultSchemaBrowseIsUnqualified() throws {
        let query = try builder(for: .spanner).buildBaseQuery(tableName: "Orders", schemaName: "(default)")
        #expect(query == "SELECT * FROM `Orders` LIMIT 200 OFFSET 0")
    }

    @Test("A table in a named Spanner schema is browsed qualified")
    func namedSchemaBrowseIsQualified() throws {
        let query = try builder(for: .spanner).buildBaseQuery(tableName: "Orders", schemaName: "sales")
        #expect(query == "SELECT * FROM `sales`.`Orders` LIMIT 200 OFFSET 0")
    }

    @Test("Filtered queries and counts drop the implicit schema too")
    func filteredQueryAndCountAreUnqualified() throws {
        let builder = try builder(for: .spanner)
        let filtered = builder.buildFilteredQuery(
            tableName: "Orders", schemaName: "(default)", filters: [activeFilter], columns: ["status"]
        )
        let count = builder.buildFilteredCountQuery(tableName: "Orders", schemaName: "(default)", filters: [])
        #expect(filtered.hasPrefix("SELECT * FROM `Orders` WHERE "))
        #expect(count == "SELECT COUNT(*) FROM `Orders`")
    }

    @Test("An engine without an implicit schema qualifies every named schema")
    func otherEnginesKeepQualifying() throws {
        let query = try builder(for: .postgresql).buildBaseQuery(tableName: "orders", schemaName: "public")
        #expect(query == "SELECT * FROM \"public\".\"orders\" LIMIT 200 OFFSET 0")
    }
}
