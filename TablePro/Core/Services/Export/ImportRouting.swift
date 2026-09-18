//
//  ImportRouting.swift
//  TablePro
//

import Foundation

struct ImportFormatOption: Identifiable, Equatable {
    let id: String
    let name: String

    var submenuLabel: String {
        String(format: String(localized: "From %@\u{2026}"), name)
    }

    var standaloneLabel: String {
        String(format: String(localized: "Import %@\u{2026}"), name)
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
