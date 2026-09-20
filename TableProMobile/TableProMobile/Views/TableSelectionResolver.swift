import Foundation
import TableProModels

nonisolated enum TableSelectionResolver {
    static func resolve(pendingName: String?, in tables: [TableInfo]) -> TableInfo? {
        guard let pendingName else { return nil }
        return tables.first { $0.name == pendingName }
    }

    static func keeping(_ selection: TableInfo?, in tables: [TableInfo]) -> TableInfo? {
        guard let selection else { return nil }
        return tables.contains(selection) ? selection : nil
    }
}
