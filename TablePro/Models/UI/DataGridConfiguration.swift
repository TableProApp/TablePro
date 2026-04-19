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
    var primaryKeyColumns: [String] = []
    var tabType: TabType?
    var showRowNumbers: Bool = true
    var hiddenColumns: Set<String> = []
}
