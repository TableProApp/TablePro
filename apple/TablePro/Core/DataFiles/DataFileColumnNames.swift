//
//  DataFileColumnNames.swift
//  TablePro
//

import Foundation
import TableProCoreTypes
import TableProTabular

struct DataFileColumnNames: Equatable {
    let ids: [TabularColumnID]
    let displayNames: [String]
    private let idByName: [String: TabularColumnID]
    private let indexByID: [TabularColumnID: Int]

    init(columns: [TabularColumn]) {
        var allocator = UniqueNameAllocator(candidate: { base, ordinal in
            ordinal == 1 ? base : "\(base) (\(ordinal))"
        })
        var names: [String] = []
        var byName: [String: TabularColumnID] = [:]
        var positions: [TabularColumnID: Int] = [:]
        names.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            let name = allocator.allocate(Self.baseName(column.name, position: index))
            names.append(name)
            byName[name] = column.id
            if positions[column.id] == nil { positions[column.id] = index }
        }
        ids = columns.map(\.id)
        displayNames = names
        idByName = byName
        indexByID = positions
    }

    var count: Int { ids.count }

    func id(forName name: String) -> TabularColumnID? {
        idByName[name]
    }

    func name(for id: TabularColumnID) -> String? {
        indexByID[id].map { displayNames[$0] }
    }

    func index(of id: TabularColumnID) -> Int? {
        indexByID[id]
    }

    private static func baseName(_ raw: String, position: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(format: String(localized: "Column %d"), position + 1)
        }
        guard trimmed != TableFilter.rawSQLColumn else { return "\(trimmed) (1)" }
        return trimmed
    }
}
