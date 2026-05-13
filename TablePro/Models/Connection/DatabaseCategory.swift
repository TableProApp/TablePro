//
//  DatabaseCategory.swift
//  TablePro
//

import Foundation

enum DatabaseCategory: String, CaseIterable, Hashable, Sendable, Comparable {
    case relational
    case document
    case keyValue
    case analytical
    case wideColumn
    case cloud
    case coordination
    case other

    var displayName: String {
        switch self {
        case .relational:   return String(localized: "Relational")
        case .document:     return String(localized: "Document")
        case .keyValue:     return String(localized: "Key-Value")
        case .analytical:   return String(localized: "Analytical")
        case .wideColumn:   return String(localized: "Wide-Column")
        case .cloud:        return String(localized: "Cloud Native")
        case .coordination: return String(localized: "Coordination & Config")
        case .other:        return String(localized: "Other")
        }
    }

    var sortOrder: Int {
        switch self {
        case .relational:   return 0
        case .document:     return 1
        case .keyValue:     return 2
        case .analytical:   return 3
        case .wideColumn:   return 4
        case .cloud:        return 5
        case .coordination: return 6
        case .other:        return 7
        }
    }

    static func < (lhs: DatabaseCategory, rhs: DatabaseCategory) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
