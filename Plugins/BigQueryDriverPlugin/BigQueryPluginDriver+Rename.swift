import Foundation
import TableProPluginKit

extension BigQueryPluginDriver {
    private static let renamableObjectKeywords: Set<String> = ["TABLE", "VIEW", "MATERIALIZED VIEW"]

    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = quoteIdentifier(name)
        let target = schema.map { "\(quoteIdentifier($0)).\(quoted)" } ?? quoted
        let requested = objectType.uppercased()
        let keyword = Self.renamableObjectKeywords.contains(requested) ? requested : "TABLE"
        _ = try await execute(query: "ALTER \(keyword) \(target) RENAME TO \(quoteIdentifier(newName))")
    }
}
