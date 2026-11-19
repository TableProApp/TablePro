import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CommentingStubDriver: PluginDriverStub, @unchecked Sendable {
    let commentableTypes: Set<String>
    private(set) var metadataReads: [String] = []
    private(set) var indexReads: [String] = []

    init(commentableTypes: Set<String>) {
        self.commentableTypes = commentableTypes
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        commentableTypes.contains(objectType) ? "COMMENT ON \(objectType) \(name)" : nil
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        metadataReads.append("\(schema ?? "").\(table)")
        return PluginTableMetadata(tableName: table, comment: table == "blank" ? "  " : "about \(table)")
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        indexReads.append("\(schema ?? "").\(table)")
        return [PluginIndexInfo(name: "\(table)_pkey", columns: ["id"], isPrimary: true)]
    }
}

private final class CatalogCommentStubDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var metadataReads = 0

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        "COMMENT ON \(objectType) \(name)"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        metadataReads += 1
        return PluginTableMetadata(tableName: table, rowCount: 100_001, comment: "from metadata")
    }

    func fetchObjectComment(table: String, schema: String?) async throws -> String? {
        "from the catalog"
    }
}

private final class SchemaReadStubDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var reads: [String] = []

    var exportBulkReads: PluginExportBulkReads { [.indexDDL, .dependentTypes] }

    func fetchAllIndexDDL(schema: String?) async throws -> [String: [String]] {
        reads.append("index \(schema ?? "")")
        return ["orders": ["CREATE INDEX orders_day ON sales.orders (day)"]]
    }

    func fetchAllCommentDDL(schema: String?) async throws -> [String: [String]] {
        reads.append("comments \(schema ?? "")")
        return ["orders": ["COMMENT ON TABLE sales.orders IS 'Orders'"]]
    }

    func fetchAllDependentSequences(schema: String?) async throws -> [String: [PluginSequenceInfo]] {
        reads.append("sequences \(schema ?? "")")
        return ["orders": [PluginSequenceInfo(name: "orders_id_seq", ddl: "CREATE SEQUENCE orders_id_seq;")]]
    }

    func fetchAllDependentTypes(schema: String?) async throws -> [String: [PluginEnumTypeInfo]] {
        reads.append("types \(schema ?? "")")
        return ["orders": [PluginEnumTypeInfo(name: "status", labels: ["new", "paid"])]]
    }
}

struct ExportDataSourceAdapterCatalogTests {
    private func adapter(_ stub: CommentingStubDriver) -> ExportDataSourceAdapter {
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: stub)
        return ExportDataSourceAdapter(driver: driver, databaseType: .postgresql)
    }

    private func object(_ name: String, kind: PluginExportObjectKind) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "sales", tableType: kind.rawValue, schema: "sales", kind: kind)
    }

    @Test("A comment is read for the kinds the engine can comment on, in the object's own schema")
    func commentIsReadWhereTheEngineStoresOne() async throws {
        let stub = CommentingStubDriver(commentableTypes: ["TABLE"])
        let source = adapter(stub)

        #expect(try await source.fetchObjectComment(object("orders", kind: .table)) == "about orders")
        #expect(try await source.fetchObjectComment(object("recent", kind: .view)) == nil)
        #expect(try await source.fetchObjectComment(object("blank", kind: .table)) == nil)
        #expect(stub.metadataReads == ["sales.orders", "sales.blank"])
    }

    @Test("An engine that stores no comments is never asked for table metadata, which may count rows")
    func noCommentsMeansNoMetadataRead() async throws {
        let stub = CommentingStubDriver(commentableTypes: [])
        let source = adapter(stub)

        #expect(try await source.fetchObjectComment(object("orders", kind: .table)) == nil)
        #expect(stub.metadataReads.isEmpty)
    }

    @Test("A driver that reads its comment from the catalog is never asked for table metadata")
    func catalogCommentSkipsTheMetadataRead() async throws {
        let stub = CatalogCommentStubDriver()
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .duckdb), pluginDriver: stub)
        let source = ExportDataSourceAdapter(driver: driver, databaseType: .duckdb)

        #expect(try await source.fetchObjectComment(object("orders", kind: .table)) == "from the catalog")
        #expect(try await driver.fetchObjectComment(tableName: "orders") == "from the catalog")
        #expect(stub.metadataReads == 0)
    }

    @Test("Indexes are read from the driver in the container the export named")
    func indexesComeFromTheNamedContainer() async throws {
        let stub = CommentingStubDriver(commentableTypes: [])
        let indexes = try await adapter(stub).fetchIndexes(table: "orders", databaseName: "sales")

        #expect(indexes.map { $0.name } == ["orders_pkey"])
        #expect(stub.indexReads == ["sales.orders"])
    }

    @Test("Schema-wide export reads come from the driver in the container the export named, under the driver's gate")
    func schemaReadsComeFromTheNamedContainer() async throws {
        let stub = SchemaReadStubDriver()
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: stub)
        let source = ExportDataSourceAdapter(driver: driver, databaseType: .postgresql)

        let indexDDL = try await source.fetchAllIndexDDL(databaseName: "sales")
        let commentDDL = try await source.fetchAllCommentDDL(databaseName: "sales")
        let sequences = try await source.fetchAllDependentSequences(databaseName: "sales")
        let types = try await source.fetchAllDependentTypes(databaseName: "sales")

        #expect(source.bulkReads == [.indexDDL, .dependentTypes])
        #expect(indexDDL == ["orders": ["CREATE INDEX orders_day ON sales.orders (day)"]])
        #expect(commentDDL == ["orders": ["COMMENT ON TABLE sales.orders IS 'Orders'"]])
        #expect(sequences["orders"]?.map { $0.ddl } == ["CREATE SEQUENCE orders_id_seq;"])
        #expect(types["orders"]?.map { $0.labels } == [["new", "paid"]])
        #expect(stub.reads == ["index sales", "comments sales", "sequences sales", "types sales"])
    }
}
