//
//  ContextItem+Display.swift
//  TablePro
//

import Foundation

extension ContextItem {
    var displayLabel: String {
        switch self {
        case .schema:
            return String(localized: "Schema")
        case .table(_, let name):
            return name
        case .currentQuery:
            return String(localized: "Current Query")
        case .queryResult:
            return String(localized: "Query Results")
        case .savedQuery:
            return String(localized: "Saved Query")
        case .file(let url):
            return url.lastPathComponent
        }
    }

    var symbolName: String {
        switch self {
        case .schema:
            return "tablecells"
        case .table:
            return "tablecells.badge.ellipsis"
        case .currentQuery:
            return "doc.text"
        case .queryResult:
            return "list.bullet.rectangle"
        case .savedQuery:
            return "star"
        case .file:
            return "doc"
        }
    }

    var stableKey: String {
        switch self {
        case .schema(let connectionId):
            return "schema:\(connectionId.uuidString)"
        case .table(let connectionId, let name):
            return "table:\(connectionId.uuidString):\(name)"
        case .currentQuery:
            return "currentQuery"
        case .queryResult:
            return "queryResult"
        case .savedQuery(let id):
            return "savedQuery:\(id.uuidString)"
        case .file(let url):
            return "file:\(url.absoluteString)"
        }
    }
}
