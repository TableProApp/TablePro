//
//  ImportRouting.swift
//  TablePro
//

import Foundation

struct ImportFormatOption: Identifiable, Equatable {
    let id: String
    let name: String

    /// The plugin's own `acceptedFileExtensions`, carried so a file panel and
    /// `ImportFileFormatResolver` can be built from the option alone rather than reaching back into
    /// `PluginManager` for the plugin type.
    let acceptedFileExtensions: [String]

    init(id: String, name: String, acceptedFileExtensions: [String] = []) {
        self.id = id
        self.name = name
        self.acceptedFileExtensions = acceptedFileExtensions
    }

    var submenuLabel: String {
        String(format: String(localized: "From %@\u{2026}"), name)
    }

    var standaloneLabel: String {
        String(format: String(localized: "Import %@\u{2026}"), name)
    }

    /// The format's name alone, for a menu whose parent already names the command: Import Data From
    /// > CSV…, the shape Keynote and Numbers give Export To. Under that parent `submenuLabel` would
    /// read "Import Data From > From CSV…". Not localized, because the format's name is the whole of
    /// it and a format name is a technical term.
    var formatLabel: String {
        "\(name)\u{2026}"
    }
}

enum ImportSheetRoute: Equatable {
    case statement(formatId: String)
    case rowMapping(formatId: String)
}

enum ImportRouting {
    static func route(formatId: String, requiresTargetTable: Bool) -> ImportSheetRoute {
        requiresTargetTable ? .rowMapping(formatId: formatId) : .statement(formatId: formatId)
    }

    /// Whether the statement dialog can actually run a format. It runs a file of statements, so a
    /// format needing a target table belongs to `RowImportSheet`; offering one in the statement
    /// dialog's picker only ever produced "No target table configured for row import" on Import.
    static func isStatementFormat(
        requiresTargetTable: Bool,
        supportedDatabaseTypeIds: [String],
        excludedDatabaseTypeIds: [String],
        databaseTypeId: String
    ) -> Bool {
        if requiresTargetTable {
            return false
        }
        if !supportedDatabaseTypeIds.isEmpty, !supportedDatabaseTypeIds.contains(databaseTypeId) {
            return false
        }
        return !excludedDatabaseTypeIds.contains(databaseTypeId)
    }
}
