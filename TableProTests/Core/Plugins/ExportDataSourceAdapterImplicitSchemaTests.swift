import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SchemaAwareStubDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var currentSchema: String? { "sales" }
}

private final class SchemaLessStubDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
}

struct ExportDataSourceAdapterImplicitSchemaTests {
    private func adapter(for type: DatabaseType) -> ExportDataSourceAdapter {
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: type), pluginDriver: SchemaAwareStubDriver()
        )
        return ExportDataSourceAdapter(driver: driver, databaseType: type)
    }

    @Test("An export plugin is handed no container name for a table in the implicit schema")
    func implicitSchemaIsHandedOnAsEmpty() {
        let spanner = adapter(for: .spanner)
        #expect(spanner.pluginDatabaseName(for: "(default)") == "")
        #expect(spanner.pluginDatabaseName(for: "sales") == "sales")
    }

    @Test("An empty container name reads back as the implicit schema, not the schema the driver is on")
    func emptyContainerMeansTheImplicitSchema() {
        let spanner = adapter(for: .spanner)
        #expect(spanner.exportSchema(for: "") == "(default)")
        #expect(spanner.exportSchema(for: "(default)") == "(default)")
        #expect(spanner.exportSchema(for: "sales") == "sales")
    }

    @Test("An engine without an implicit schema keeps both answers as they were")
    func otherEnginesUnchanged() {
        let postgres = adapter(for: .postgresql)
        #expect(postgres.pluginDatabaseName(for: "public") == "public")
        #expect(postgres.pluginDatabaseName(for: "") == "")
        #expect(postgres.exportSchema(for: "") == "sales")
        #expect(postgres.exportSchema(for: "public") == "public")
    }

    /// The export names its groups after databases on an engine with no schema layer, and that name
    /// is the container the driver has to read in. Withholding it left a MySQL dump taking its DDL
    /// and column metadata from whichever database the connection was on while the rows came from
    /// the one the export named.
    @Test("A driver with no schema layer is handed the container the export named")
    func schemaLessDriverIsHandedTheContainer() {
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: SchemaLessStubDriver()
        )
        let mysql = ExportDataSourceAdapter(driver: driver, databaseType: .mysql)
        #expect(mysql.exportSchema(for: "crm") == "crm")
        #expect(mysql.exportSchema(for: "") == nil)
    }
}
