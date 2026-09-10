//
//  ColumnType+PluginColumnKind.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension ColumnType {
    var pluginColumnKind: PluginColumnKind {
        switch self {
        case .text, .enumType, .set, .array:
            return .text
        case .integer:
            return .integer
        case .decimal:
            return .decimal
        case .boolean:
            return .boolean
        case .date, .timestamp, .datetime, .blob, .json, .spatial:
            return .other
        }
    }
}
