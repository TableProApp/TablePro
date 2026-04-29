//
//  ColumnLayoutPersisting.swift
//  TablePro
//

import Foundation

@MainActor
protocol ColumnLayoutPersisting: AnyObject {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState?
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID)
    func clear(for tableName: String, connectionId: UUID)
}
