import Foundation
import TableProModels
import TableProPluginKit

// One instance of each format plugin for the app's life: a form edits its `settings`, and the run reads them once.
nonisolated enum MobileExportFormats {
    static let csv = CSVExportPlugin()
    static let json = JSONExportPlugin()
    static let sql = SQLExportPlugin()
    static let xlsx = XLSXExportPlugin()
    static let markdown = MarkdownExportPlugin()
    static let mql = MQLExportPlugin()

    static var all: [any ExportFormatPlugin] {
        ExportFormatOffer.sorted([csv, json, sql, xlsx, markdown, mql])
    }

    static func available(for databaseType: DatabaseType) -> [any ExportFormatPlugin] {
        ExportFormatOffer.offered(all, forDatabaseTypeId: databaseType.rawValue)
    }

    static func plugin(formatId: String) -> (any ExportFormatPlugin)? {
        all.first { type(of: $0).formatId == formatId }
    }
}
