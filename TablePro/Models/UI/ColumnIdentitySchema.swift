//
//  ColumnIdentitySchema.swift
//  TablePro
//

import AppKit

struct ColumnIdentitySchema: Equatable {
    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("__rowNumber__")
    static let dataColumnPrefix = "dataColumn-"

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

    static func slotIdentifier(_ slot: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("\(dataColumnPrefix)\(slot)")
    }
}
