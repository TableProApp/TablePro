import Foundation
import TableProPluginKit

// Which export formats an engine is offered, and in what order, for both apps' export sheets.
nonisolated enum ExportFormatOffer {
    static let dataDictionaryFormatId = "datadict"

    private static let displayOrder = [
        "csv", "json", "sql", "xlsx", "md", "parquet", "mql", dataDictionaryFormatId
    ]

    static func offered(_ plugins: [any ExportFormatPlugin], forDatabaseTypeId databaseTypeId: String) -> [any ExportFormatPlugin] {
        sorted(plugins.filter { accepts($0, databaseTypeId: databaseTypeId) })
    }

    static func accepts(_ plugin: any ExportFormatPlugin, databaseTypeId: String) -> Bool {
        let pluginType = type(of: plugin)
        return accepts(
            databaseTypeId: databaseTypeId,
            supportedDatabaseTypeIds: pluginType.supportedDatabaseTypeIds,
            excludedDatabaseTypeIds: pluginType.excludedDatabaseTypeIds
        )
    }

    static func accepts(
        databaseTypeId: String,
        supportedDatabaseTypeIds: [String],
        excludedDatabaseTypeIds: [String]
    ) -> Bool {
        guard supportedDatabaseTypeIds.isEmpty else {
            return supportedDatabaseTypeIds.contains(databaseTypeId)
        }
        return !excludedDatabaseTypeIds.contains(databaseTypeId)
    }

    // A format missing from the curated order, such as a registry one, sorts after it by display name.
    static func sorted(_ plugins: [any ExportFormatPlugin]) -> [any ExportFormatPlugin] {
        plugins.sorted { first, second in
            let firstRank = rank(of: type(of: first).formatId)
            let secondRank = rank(of: type(of: second).formatId)
            guard firstRank == secondRank else { return firstRank < secondRank }
            return type(of: first).formatDisplayName
                .localizedCaseInsensitiveCompare(type(of: second).formatDisplayName) == .orderedAscending
        }
    }

    private static func rank(of formatId: String) -> Int {
        displayOrder.firstIndex(of: formatId) ?? displayOrder.count
    }
}
