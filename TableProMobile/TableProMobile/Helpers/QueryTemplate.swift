import Foundation
import TableProModels

nonisolated enum QueryTemplate {
    static let selectAllRowLimit = 100

    static func selectAll(table: String, schema: String?, type: DatabaseType) -> String? {
        guard type.speaksSQL else { return nil }
        return SQLBuilder.buildSelect(table: table, schema: schema, type: type, limit: selectAllRowLimit, offset: 0)
    }
}
