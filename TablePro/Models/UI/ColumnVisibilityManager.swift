//
//  ColumnVisibilityManager.swift
//  TablePro
//

import Foundation
import Observation

@MainActor @Observable
internal final class ColumnVisibilityManager {
    private(set) var hiddenColumns: Set<String> = []

    var hasHiddenColumns: Bool {
        !hiddenColumns.isEmpty
    }

    var hiddenCount: Int {
        hiddenColumns.count
    }

    func toggleColumn(_ columnName: String) {
        if hiddenColumns.contains(columnName) {
            hiddenColumns.remove(columnName)
        } else {
            hiddenColumns.insert(columnName)
        }
    }

    func hideColumn(_ columnName: String) {
        hiddenColumns.insert(columnName)
    }

    func showColumn(_ columnName: String) {
        hiddenColumns.remove(columnName)
    }

    func showAll() {
        hiddenColumns.removeAll()
    }

    func hideAll(_ columns: [String]) {
        hiddenColumns = Set(columns)
    }

    // MARK: - Per-Tab Persistence

    func saveToColumnLayout() -> Set<String> {
        hiddenColumns
    }

    func restoreFromColumnLayout(_ columns: Set<String>) {
        hiddenColumns = columns
    }

    // MARK: - Per-Table UserDefaults Persistence

    func saveLastHiddenColumns(for tableName: String, connectionId: UUID) {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        let array = Array(hiddenColumns)
        UserDefaults.standard.set(array, forKey: key)
    }

    func restoreLastHiddenColumns(for tableName: String, connectionId: UUID) {
        let key = Self.userDefaultsKey(tableName: tableName, connectionId: connectionId)
        if let array = UserDefaults.standard.stringArray(forKey: key) {
            hiddenColumns = Set(array)
        } else {
            hiddenColumns = []
        }
    }

    /// Remove hidden column names that no longer exist in the current result set
    func pruneStaleColumns(_ currentColumns: [String]) {
        let currentSet = Set(currentColumns)
        hiddenColumns = hiddenColumns.intersection(currentSet)
    }

    // MARK: - Private

    private static func userDefaultsKey(tableName: String, connectionId: UUID) -> String {
        "com.TablePro.columns.hiddenColumns.\(connectionId.uuidString).\(tableName)"
    }
}
