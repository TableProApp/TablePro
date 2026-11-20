import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class TwinCompareDriver: PluginDriverStub, @unchecked Sendable {
    var providesBulkColumnFetch: Bool { true }
    var providesBulkIndexFetch: Bool { true }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let name = table.utf8.elementsEqual(TwinNames.composed.utf8) ? "a" : "b"
        return [PluginColumnInfo(name: name, dataType: "int")]
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        throw PluginCatalogNameCollision(name: TwinNames.decomposed)
    }

    // Only the composed twin has an index, so the answer holds one spelling and the read does not throw.
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        [TwinNames.composed: [PluginIndexInfo(name: "composed_pkey", columns: ["id"], isUnique: true, isPrimary: true)]]
    }
}

struct CompareTwinTableReadTests {
    @Test("Each of two tables whose names differ only in Unicode form compares its own columns and indexes")
    func twinsReadTheirOwnStructure() async throws {
        let tables = [TwinNames.composed, TwinNames.decomposed].map {
            PluginTableInfo(name: $0, schema: "public", comment: nil)
        }

        let reads = try await CompareMetadataService.read(
            tables: tables, schema: "public", profile: .structure,
            narrowed: false, databaseType: .postgresql, indexedKinds: [], using: TwinCompareDriver()
        )

        #expect(reads.map { $0.columns.map(\.name) } == [["a"], ["b"]])
        #expect(reads.map { $0.indexes.map(\.name) } == [["composed_pkey"], []])
    }
}
