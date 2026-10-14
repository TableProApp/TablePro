import Foundation
@testable import TablePro
import TableProPluginKit

internal final class IndexStatementStubDriver: PluginDriverStub, @unchecked Sendable {
    internal let indexSchema: String
    internal let writesIndexes: Bool

    internal init(indexSchema: String = "public", writesIndexes: Bool = true) {
        self.indexSchema = indexSchema
        self.writesIndexes = writesIndexes
    }

    internal var currentSchema: String? { indexSchema }

    internal func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    // The statement PostgreSQLIndexClauses writes for an index built from its fields.
    internal func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard writesIndexes else { return nil }
        let unique = index.isUnique ? "UNIQUE " : ""
        let method = index.indexType.map { "USING \($0.lowercased()) " } ?? ""
        let keys = index.columns.map(quoteIdentifier).joined(separator: ", ")
        let qualifiedTable = "\(quoteIdentifier(indexSchema)).\(quoteIdentifier(table))"
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) \(method)(\(keys))"
    }

    internal func generateDropIndexSQL(table: String, indexName: String) -> String? {
        guard writesIndexes else { return nil }
        return "DROP INDEX \(quoteIdentifier(indexSchema)).\(quoteIdentifier(indexName))"
    }
}
