//
//  ShareRequest.swift
//  TablePro
//

import Foundation

// Reads up to the plan's row limit once the sheet knows it; nil when the rows are gone.
internal typealias ShareResultLoader = @MainActor @Sendable (_ maxRows: Int) async -> ShareResultSource?

// What a Share sheet was opened for: a query, or a query with the result it produced.
internal struct ShareRequest: Identifiable {
    let id = UUID()
    let kind: ShareKind
    let title: String
    let sql: String
    let dialect: String?
    let loadResult: ShareResultLoader?

    static func query(title: String, sql: String, dialect: String?) -> ShareRequest {
        ShareRequest(kind: .query, title: title, sql: sql, dialect: dialect, loadResult: nil)
    }

    static func result(title: String, sql: String, dialect: String?, load: @escaping ShareResultLoader) -> ShareRequest {
        ShareRequest(kind: .result, title: title, sql: sql, dialect: dialect, loadResult: load)
    }

    static func result(title: String, dialect: String?, source: ShareResultSource) -> ShareRequest {
        result(title: title, sql: source.sql, dialect: dialect) { _ in source }
    }
}
