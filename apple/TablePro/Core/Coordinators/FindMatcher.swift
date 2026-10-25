//
//  FindMatcher.swift
//  TablePro
//

import Foundation

enum FindMatcher {
    // A binary column is searchable once a display format has turned its bytes into characters; hex is not.
    static func isSearchable(_ columnType: ColumnType?, displayFormat: ValueDisplayFormat? = nil) -> Bool {
        switch columnType {
        case .blob: displayFormat?.rendersBinaryAsText == true
        case .spatial: false
        default: true
        }
    }

    // Postgres has no implicit integer to text cast, so `id ILIKE '%abc%'` fails the whole query instead of matching
    // nothing. An engine whose patterns read a scalar column by its shown text searches those too; JSON is text only on screen.
    static func isServerSearchable(_ columnType: ColumnType?, patternReadsAnyColumn: Bool = false) -> Bool {
        if patternReadsAnyColumn, columnType?.isJsonType != true { return isSearchable(columnType) }
        return switch columnType {
        case .text, .enumType, .set, nil: true
        default: false
        }
    }
}
