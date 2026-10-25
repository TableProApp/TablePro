//
//  DataGridConfiguration.swift
//  TablePro
//

import Foundation

// What a grid offers. Where its rows came from lives in `traits`; where its layout is saved lives in its store.
struct DataGridConfiguration: Equatable {
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var customDropdownOptions: [Int: [GridMenuOption]]?
    var primaryKeyColumns: [String] = []
    var showRowNumbers: Bool = true

    // Keyed by index: the column is the grid's own and has no name a table column could share.
    var checkboxColumns: Set<Int> = []

    var supportsValueFilter: Bool = true

    // PostgreSQL renames a view's column and sets its default but refuses its NOT NULL and type (#2726).
    var lockedColumns: Set<String> = []

    // A result's rows, not a list of columns: the Data Grid sort preferences apply.
    var appliesRowSortPreferences: Bool = false

    // Off on the Structure grids, whose Copy writes definitions a paste reads back.
    var appliesRowCopyFormat: Bool = false

    // A Cassandra table cannot be ordered by an arbitrary column.
    var supportsColumnSort: Bool = true

    // A grid that refuses every keystroke silently reads as broken.
    var editRefusalMessage: String?

    var columnMinimumWidths: [String: CGFloat] = [:]

    var isEditable: Bool = false

    var commands: Set<DataGridCommand> = []

    var traits: DataGridEngineTraits = .none

    var rowReorder: DataGridRowReorder = .disabled

    // VoiceOver's name for the grid ("Active Sessions"); nil reads "Data grid".
    var accessibilityLabel: String?
}
