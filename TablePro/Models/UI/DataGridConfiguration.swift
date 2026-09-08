//
//  DataGridConfiguration.swift
//  TablePro
//
//  Configuration struct for DataGridView, replacing individual config properties.
//

import Foundation

struct DataGridConfiguration: Equatable {
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var customDropdownOptions: [Int: [String]]?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var databaseName: String?
    var schemaName: String?
    var primaryKeyColumns: [String] = []
    var tabType: TabType?
    var showRowNumbers: Bool = true
    var hiddenColumns: Set<String> = []

    /// This grid shows rows of a result, so the Data Grid sort preferences apply to it.
    ///
    /// `tabType` cannot answer this: the Structure grid runs inside a `.table` tab and lists columns,
    /// and a query result runs in a `.query` tab and is as much the data grid as a table is. The
    /// question is what the grid holds, not which tab it sits in.
    var appliesRowSortPreferences: Bool = false

    /// Why these rows cannot be written back, when they cannot. A grid that silently refuses every
    /// keystroke reads as broken, so the reason rides with the configuration and the grid shows it.
    var editRefusalMessage: String?
}
