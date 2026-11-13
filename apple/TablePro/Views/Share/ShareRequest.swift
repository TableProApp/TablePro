//
//  ShareRequest.swift
//  TablePro
//

import Foundation

// What a Share sheet was opened for: a query, or a query with the result it produced.
internal struct ShareRequest: Identifiable {
    let id = UUID()
    let kind: ShareKind
    let title: String
    let sql: String
    let dialect: String?
    let result: ShareResultSource?

    static func query(title: String, sql: String, dialect: String?) -> ShareRequest {
        ShareRequest(kind: .query, title: title, sql: sql, dialect: dialect, result: nil)
    }

    static func result(title: String, sql: String, dialect: String?, source: ShareResultSource) -> ShareRequest {
        ShareRequest(kind: .result, title: title, sql: sql, dialect: dialect, result: source)
    }
}
