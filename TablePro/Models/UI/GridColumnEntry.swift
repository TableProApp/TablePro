//
//  GridColumnEntry.swift
//  TablePro
//

import Foundation

/// One column as the Columns popover and Jump to Column both list it.
///
/// `dataIndex` is nil for a column the user hid on a table tab, because a hidden column is not
/// fetched and so has no place in the result; it is still listed so it can be shown again.
/// `position` is the column's 1-based place among the columns the grid presents, in the order the
/// grid presents them, so a reordered column reports where the reader sees it rather than where the
/// result put it.
struct GridColumnEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let dataIndex: Int?
    let typeName: String?
    let position: Int?
    let isHidden: Bool

    init(name: String, dataIndex: Int?, typeName: String?, position: Int?, isHidden: Bool) {
        self.id = dataIndex.map { "column-\($0)" } ?? "hidden-\(name)"
        self.name = name
        self.dataIndex = dataIndex
        self.typeName = typeName
        self.position = position
        self.isHidden = isHidden
    }
}

enum GridColumnCatalog {
    /// The catalog keeps one entry per physical column, and a join routinely carries two columns
    /// with one name. Visibility is kept by name, so anything that counts or toggles visibility
    /// reads this projection: the first entry of each name, in catalog order.
    static func uniqueByName(_ entries: [GridColumnEntry]) -> [GridColumnEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.name).inserted }
    }

    /// - Parameters:
    ///   - displayOrder: data indices of the presented columns in the order the grid shows them,
    ///     or nil when no grid is mounted, in which case the result's own order stands in.
    ///   - pickerColumns: every column the Columns popover offers, which on a table tab includes
    ///     the schema's columns the result left out because they are hidden.
    static func entries(
        resultColumns: [String],
        columnTypes: [ColumnType],
        hiddenColumns: Set<String>,
        displayOrder: [Int]?,
        pickerColumns: [String]
    ) -> [GridColumnEntry] {
        let presented = displayOrder
            ?? resultColumns.indices.filter { !hiddenColumns.contains(resultColumns[$0]) }
        var positionByDataIndex: [Int: Int] = [:]
        positionByDataIndex.reserveCapacity(presented.count)
        for (offset, dataIndex) in presented.enumerated() {
            positionByDataIndex[dataIndex] = offset + 1
        }

        var dataIndicesByName: [String: [Int]] = [:]
        for (dataIndex, name) in resultColumns.enumerated() {
            dataIndicesByName[name, default: []].append(dataIndex)
        }

        func resultEntry(_ dataIndex: Int) -> GridColumnEntry {
            let name = resultColumns[dataIndex]
            let type = dataIndex < columnTypes.count ? columnTypes[dataIndex] : nil
            let isHidden = hiddenColumns.contains(name)
            return GridColumnEntry(
                name: name,
                dataIndex: dataIndex,
                typeName: type.map { $0.rawType ?? $0.displayName },
                position: isHidden ? nil : positionByDataIndex[dataIndex],
                isHidden: isHidden
            )
        }

        var entries: [GridColumnEntry] = []
        entries.reserveCapacity(max(pickerColumns.count, resultColumns.count))
        var listedNames = Set<String>()
        for name in pickerColumns {
            guard listedNames.insert(name).inserted else { continue }
            guard let dataIndices = dataIndicesByName.removeValue(forKey: name) else {
                entries.append(GridColumnEntry(name: name, dataIndex: nil, typeName: nil, position: nil, isHidden: true))
                continue
            }
            for dataIndex in dataIndices {
                entries.append(resultEntry(dataIndex))
            }
        }
        let unlisted = dataIndicesByName.values.flatMap { $0 }.sorted()
        for dataIndex in unlisted {
            entries.append(resultEntry(dataIndex))
        }
        return entries
    }
}
