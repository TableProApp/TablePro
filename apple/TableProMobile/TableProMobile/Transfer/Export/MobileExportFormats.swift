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

    static func frozen(_ shared: any ExportFormatPlugin) -> any ExportFormatPlugin {
        let fresh = type(of: shared).init()
        RunPluginSettings.copy(from: shared, to: fresh)
        return fresh
    }
}

// A run gets a plugin of its own holding the settings the shared one had when the user confirmed, so another window
// editing the shared form cannot change a run that is already decided. Restoring re-saves the same values as the
// defaults, which is harmless.
nonisolated enum RunPluginSettings {
    static func copy(from shared: AnyObject, to fresh: AnyObject) {
        guard let source = shared as? any SettablePluginDiscoverable, let data = source.snapshotSettingsData(),
              let target = fresh as? any SettablePluginDiscoverable else { return }
        target.restoreSettingsData(data)
    }
}
