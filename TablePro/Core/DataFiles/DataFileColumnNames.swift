//
//  DataFileColumnNames.swift
//  TablePro
//

import Foundation
import TableProTabular

struct DataFileColumnNames: Equatable {
    let ids: [TabularColumnID]
    let displayNames: [String]
    private let idByName: [String: TabularColumnID]

    init(columns: [TabularColumn]) {
        var used = Set<String>()
        var names: [String] = []
        var byName: [String: TabularColumnID] = [:]
        names.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            let base = Self.baseName(column.name, position: index)
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(base) (\(suffix))"
                suffix += 1
            }
            used.insert(candidate)
            names.append(candidate)
            byName[candidate] = column.id
        }
        ids = columns.map(\.id)
        displayNames = names
        idByName = byName
    }

    var count: Int { ids.count }

    func id(forName name: String) -> TabularColumnID? {
        idByName[name]
    }

    func name(for id: TabularColumnID) -> String? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return displayNames[index]
    }

    func index(of id: TabularColumnID) -> Int? {
        ids.firstIndex(of: id)
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
