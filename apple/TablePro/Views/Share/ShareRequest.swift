//
//  ShareRequest.swift
//  TablePro
//

import Combine
import Foundation

// Reads up to the plan's row limit once the sheet knows it; nil when the result is no longer open.
internal typealias ShareResultLoader = @MainActor @Sendable (_ maxRows: Int) async -> ShareResultSource?

// What a Share sheet was opened for: a query, or a query with the result it produced.
internal struct ShareRequest: Identifiable {
    let id = UUID()
    let kind: ShareKind
    let title: String
    let sql: String
    let dialect: String?
    let loadResult: ShareResultLoader?
    // Fires when the rows the loader reads were masked again, as after a masking rule is saved.
    let sourceChanges: AnyPublisher<Void, Never>?

    static func query(title: String, sql: String, dialect: String?) -> ShareRequest {
        ShareRequest(kind: .query, title: title, sql: sql, dialect: dialect, loadResult: nil, sourceChanges: nil)
    }

    static func result(
        title: String,
        sql: String,
        dialect: String?,
        sourceChanges: AnyPublisher<Void, Never>? = nil,
        load: @escaping ShareResultLoader
    ) -> ShareRequest {
        ShareRequest(kind: .result, title: title, sql: sql, dialect: dialect, loadResult: load, sourceChanges: sourceChanges)
    }

    static func result(title: String, dialect: String?, source: ShareResultSource) -> ShareRequest {
        result(title: title, sql: source.sql, dialect: dialect) { _ in source }
    }
}
