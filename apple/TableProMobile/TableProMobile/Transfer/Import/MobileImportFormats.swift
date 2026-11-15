import Foundation
import TableProModels
import TableProPluginKit

nonisolated enum MobileImportFormats {
    static let csv = CSVImportPlugin()
    static let json = JSONImportPlugin()
    static let xlsx = XLSXImportPlugin()
    static let sql = SQLImportPlugin()

    static var all: [any ImportFormatPlugin] {
        [csv, json, xlsx, sql]
    }

    static var acceptedFileExtensions: [String] {
        all.flatMap { type(of: $0).acceptedFileExtensions.map { $0.lowercased() } }
    }

    static func plugin(formatId: String) -> (any ImportFormatPlugin)? {
        all.first { type(of: $0).formatId == formatId }
    }

    // By the lowercased extension, never by UTType, as macOS `ImportFileFormatResolver` reads a file. A compressed row
    // file is refused by name: only a SQL dump is read through gzip.
    static func plugin(forFileExtension fileExtension: String) -> (any ImportFormatPlugin)? {
        let lowered = fileExtension.lowercased()
        return all.first { type(of: $0).acceptedFileExtensions.contains { $0.lowercased() == lowered } }
    }

    static func plugin(for url: URL) -> (any ImportFormatPlugin)? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".gz") {
            let inner = url.deletingPathExtension().pathExtension.lowercased()
            guard inner.isEmpty || inner == "sql" else { return nil }
            return sql
        }
        return plugin(forFileExtension: url.pathExtension)
    }

    // Rows go into a table through SQL; MongoDB and Redis take none (macOS D9), and neither runs a SQL file.
    static func rowFormats(for databaseType: DatabaseType) -> [any ImportFormatPlugin] {
        guard databaseType.speaksSQL else { return [] }
        return all.filter { type(of: $0).requiresTargetTable && accepts($0, databaseTypeId: databaseType.rawValue) }
    }

    static func offersSQLFile(for databaseType: DatabaseType) -> Bool {
        databaseType.speaksSQL && accepts(sql, databaseTypeId: databaseType.rawValue)
    }

    static func accepts(_ plugin: any ImportFormatPlugin, databaseTypeId: String) -> Bool {
        let pluginType = type(of: plugin)
        guard pluginType.supportedDatabaseTypeIds.isEmpty else {
            return pluginType.supportedDatabaseTypeIds.contains(databaseTypeId)
        }
        return !pluginType.excludedDatabaseTypeIds.contains(databaseTypeId)
    }
}
