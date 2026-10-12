//
//  PluginResultColumnHints.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The name a driver asks the app to classify each result column by, beside the name it declares.
///
/// DynamoDB declares a column `Map`, `List` or `String Set`, which no SQL classifier reads as a document, and hints
/// `JSON` so the cell opens in the JSON editor while the header still reads `Map`.
enum PluginResultColumnHints {
    /// One entry per column, nil where the driver set no hint. A list that does not describe every column is
    /// ignored whole, because its entries could not be matched to columns by position.
    static func hints(from columnMeta: [PluginColumnInfo]?, columnCount: Int) -> [String?] {
        guard let columnMeta, columnMeta.count == columnCount else {
            return Array(repeating: nil, count: columnCount)
        }
        return columnMeta.map(\.classificationTypeName)
    }
}

extension ColumnType {
    /// The same kind of column under the name the server declared for it.
    func declared(as rawType: String) -> ColumnType {
        switch self {
        case .text: return .text(rawType: rawType)
        case .integer: return .integer(rawType: rawType)
        case .decimal: return .decimal(rawType: rawType)
        case .date: return .date(rawType: rawType)
        case .timestamp: return .timestamp(rawType: rawType)
        case .datetime: return .datetime(rawType: rawType)
        case .boolean: return .boolean(rawType: rawType)
        case .blob: return .blob(rawType: rawType)
        case .json: return .json(rawType: rawType)
        case .enumType(_, let values): return .enumType(rawType: rawType, values: values)
        case .set(_, let values): return .set(rawType: rawType, values: values)
        case .spatial: return .spatial(rawType: rawType)
        case .array(_, let element): return .array(rawType: rawType, element: element)
        }
    }
}
