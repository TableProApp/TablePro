//
//  DialectQuoteHelper.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLDialectError: Error, LocalizedError {
    case dialectUnavailable(typeId: String)

    var errorDescription: String? {
        switch self {
        case .dialectUnavailable(let typeId):
            return String(
                format: String(localized: "SQL dialect for %@ is not available. The plugin may not be installed or loaded."),
                typeId
            )
        }
    }
}

func quoteIdentifierFromDialect(_ dialect: SQLDialectDescriptor) -> (String) -> String {
    { dialect.quoteIdentifier($0) }
}

func resolveSQLDialect(
    for databaseType: DatabaseType,
    explicit: SQLDialectDescriptor? = nil
) throws -> SQLDialectDescriptor {
    if let explicit { return explicit }
    if let dialect = PluginMetadataRegistry.shared
        .snapshot(forTypeId: databaseType.pluginTypeId)?.editor.sqlDialect {
        return dialect
    }
    throw SQLDialectError.dialectUnavailable(typeId: databaseType.pluginTypeId)
}
