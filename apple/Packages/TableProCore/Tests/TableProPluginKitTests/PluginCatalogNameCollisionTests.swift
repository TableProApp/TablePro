import Foundation
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

private final class PerTableDriver: PluginDatabaseDriver, @unchecked Sendable {
    let names: [String]
    private(set) var reads: [String] = []

    init(names: [String]) {
        self.names = names
    }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        names.map { PluginTableInfo(name: $0, schema: schema, comment: nil) }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        reads.append(table)
        return [PluginColumnInfo(name: "id", dataType: "int")]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        reads.append(table)
        return [PluginIndexInfo(name: "\(table)_pkey", columns: ["id"], isPrimary: true)]
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        reads.append(table)
        return [PluginForeignKeyInfo(name: "fk", column: "id", referencedTable: "p", referencedColumn: "id")]
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        reads.append(table)
        return PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

struct PluginCatalogNameCollisionTests {
    @Test("The per-table defaults refuse a schema holding two spellings of one name before reading it")
    func defaultsThrowOnTwins() async throws {
        let driver = PerTableDriver(names: [composed, "orders", decomposed])

        await #expect(throws: PluginCatalogNameCollision.self) { try await driver.fetchAllColumns(schema: "s") }
        await #expect(throws: PluginCatalogNameCollision.self) { try await driver.fetchAllForeignKeys(schema: "s") }
        await #expect(throws: PluginCatalogNameCollision.self) { try await driver.fetchAllIndexes(schema: "s") }
        await #expect(throws: PluginCatalogNameCollision.self) { try await driver.fetchAllTableMetadata(schema: "s") }
        #expect(driver.reads.isEmpty)
    }

    @Test("Names that differ by case, or a name listed twice in one spelling, are no collision")
    func distinctNamesStillRead() async throws {
        let driver = PerTableDriver(names: ["Users", "users", composed, composed])

        let columns = try await driver.fetchAllColumns(schema: "s")

        #expect(Set(columns.keys) == ["Users", "users", composed])
        #expect(driver.reads == ["Users", "users", composed, composed])
    }

    @Test("The collision names the object and says why")
    func collisionDescribesItself() {
        let collision = PluginCatalogNameCollision(name: composed)

        #expect(collision.name == composed)
        #expect(collision.localizedDescription.contains(composed))
    }
}
