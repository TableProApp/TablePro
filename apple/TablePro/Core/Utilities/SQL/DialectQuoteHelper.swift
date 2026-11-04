//
//  DialectQuoteHelper.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

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

// ClickHouse and GoogleSQL read a backslash inside a quoted name as an escape, so a name ending in `\` would run on.
// Databend shares MySQL's descriptor but not its doubled backtick, so it takes the driver's own spelling.
func quoteIdentifierFromDialect(
    _ dialect: SQLDialectDescriptor,
    databaseType: DatabaseType? = nil
) -> @Sendable (String) -> String {
    if databaseType == .databend {
        return { SQLQuoting.databendIdentifier($0) }
    }
    let quote = SQLIdentifierQuote(dialectQuote: dialect.identifierQuote)
    let backslashEscapes = databaseType?.lexicalGrammar.backslashEscapes(in: quote) ?? false
    return { SQLQuoting.identifier($0, quote: quote, backslashEscapes: backslashEscapes) }
}

extension SQLIdentifierQuote {
    init(dialectQuote: String) {
        switch dialectQuote {
        case "[": self = .bracket
        case "`": self = .backtick
        default: self = .doubleQuote
        }
    }
}

// MySQL's own set, `\Z` included, so a dump taken without a driver is the same file as one taken with it; ClickHouse
// and Snowflake read `\Z` as a letter, so they get the set every backslash engine decodes. Dameng detects its
// escaping at connect time and its descriptor carries the pre-detection default: ask its driver.
func escapeStringLiteralFromDialect(
    _ dialect: SQLDialectDescriptor,
    databaseType: DatabaseType? = nil
) -> @Sendable (String) -> String {
    let escapes: SQLStringEscapes
    if databaseType == .mssql {
        escapes = .sqlServer
    } else if !dialect.requiresBackslashEscaping {
        escapes = .standard
    } else if let databaseType, SqlDialect.from(databaseTypeId: databaseType.rawValue) != .mysql {
        escapes = .backslash
    } else {
        escapes = .mysql
    }
    return { SQLQuoting.stringLiteralBody($0, escapes: escapes) }
}

func resolveSQLDialect(
    for databaseType: DatabaseType,
    explicit: SQLDialectDescriptor? = nil
) throws -> SQLDialectDescriptor {
    if let explicit { return explicit }
    if let dialect = PluginMetadataRegistry.shared
        .snapshot(for: databaseType)?.editor.sqlDialect {
        return dialect
    }
    throw SQLDialectError.dialectUnavailable(typeId: databaseType.pluginTypeId)
}
