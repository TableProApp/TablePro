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
        case .savedQuery(_, let name):
            return name.isEmpty ? String(localized: "Saved Query") : name
        case .file(let url):
            return url.lastPathComponent
        case .queryContext(let attachment):
            return attachment.chipLabel
        }
    }

    var helpText: String? {
        guard case .queryContext(let attachment) = self else { return nil }
        return attachment.helpText
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
        case .queryContext:
            return "tablecells"
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
        case .savedQuery(let id, _):
            return "savedQuery:\(id.uuidString)"
        case .file(let url):
            return "file:\(url.absoluteString)"
        case .queryContext(let attachment):
            return "queryContext:\(attachment.id.uuidString)"
        }
    }
}
