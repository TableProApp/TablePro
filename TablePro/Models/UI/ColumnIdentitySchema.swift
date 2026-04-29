//
//  ColumnIdentitySchema.swift
//  TablePro
//

import AppKit

struct ColumnIdentitySchema: Equatable {
    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("__rowNumber__")

    let identifiers: [NSUserInterfaceItemIdentifier]
    let isNameBased: Bool
    private let indexByRawIdentifier: [String: Int]

    init(columns: [String]) {
        let canUseNames = Set(columns).count == columns.count
            && !columns.contains(Self.rowNumberIdentifier.rawValue)

        if canUseNames {
            self.identifiers = columns.map { NSUserInterfaceItemIdentifier($0) }
            self.isNameBased = true
        } else {
            self.identifiers = columns.indices.map {
                NSUserInterfaceItemIdentifier("col_\($0)")
            }
            self.isNameBased = false
        }

        var map: [String: Int] = [:]
        map.reserveCapacity(self.identifiers.count)
        for (index, identifier) in self.identifiers.enumerated() {
            map[identifier.rawValue] = index
        }
        self.indexByRawIdentifier = map
    }

    static let empty = ColumnIdentitySchema(columns: [])

    func identifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier? {
        guard dataIndex >= 0, dataIndex < identifiers.count else { return nil }
        return identifiers[dataIndex]
    }

    func dataIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        indexByRawIdentifier[identifier.rawValue]
    }
}
