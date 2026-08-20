//
//  ColumnIdentitySchema.swift
//  TablePro
//

import AppKit

struct ColumnIdentitySchema: Equatable {
    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("__rowNumber__")

    /// Stand-ins for the columns the window leaves unmounted, holding their width so the document
    /// keeps its full extent and the horizontal scroller still spans the whole result.
    ///
    /// Deliberately outside `dataColumnPrefix`: every loop that walks `tableView.tableColumns`
    /// resolves a data index through `dataIndex(from:)` first, so a spacer is skipped by all of
    /// them without any of those call sites learning about it.
    static let leadingSpacerIdentifier = NSUserInterfaceItemIdentifier("__leadingSpacer__")
    static let trailingSpacerIdentifier = NSUserInterfaceItemIdentifier("__trailingSpacer__")
    static let dataColumnPrefix = "dataColumn-"

    static func isSpacer(_ identifier: NSUserInterfaceItemIdentifier) -> Bool {
        identifier == leadingSpacerIdentifier || identifier == trailingSpacerIdentifier
    }

    let identifiers: [NSUserInterfaceItemIdentifier]
    let columnNames: [String]

    private let indexByRawIdentifier: [String: Int]
    private let slotByColumnName: [String: Int]

    init(columns: [String]) {
        self.columnNames = columns
        self.identifiers = columns.indices.map {
            NSUserInterfaceItemIdentifier("\(Self.dataColumnPrefix)\($0)")
        }

        var rawMap: [String: Int] = [:]
        rawMap.reserveCapacity(self.identifiers.count)
        for (index, identifier) in self.identifiers.enumerated() {
            rawMap[identifier.rawValue] = index
        }
        self.indexByRawIdentifier = rawMap

        var nameMap: [String: Int] = [:]
        nameMap.reserveCapacity(columns.count)
        for (index, name) in columns.enumerated() {
            nameMap[name] = index
        }
        self.slotByColumnName = nameMap
    }

    static let empty = ColumnIdentitySchema(columns: [])

    func identifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier? {
        guard dataIndex >= 0, dataIndex < identifiers.count else { return nil }
        return identifiers[dataIndex]
    }

    func dataIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        indexByRawIdentifier[identifier.rawValue]
    }

    func columnName(for dataIndex: Int) -> String? {
        guard dataIndex >= 0, dataIndex < columnNames.count else { return nil }
        return columnNames[dataIndex]
    }

    func dataIndex(forColumnName name: String) -> Int? {
        slotByColumnName[name]
    }

    var totalDataColumns: Int { columnNames.count }

    static func slotIdentifier(_ slot: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("\(dataColumnPrefix)\(slot)")
    }
}
