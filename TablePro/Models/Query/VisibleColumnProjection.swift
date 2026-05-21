//
//  VisibleColumnProjection.swift
//  TablePro
//

import TableProPluginKit

struct VisibleColumnProjection {
    let indices: [Int]?

    static let identity = VisibleColumnProjection(indices: nil)

    func columns(_ all: [String]) -> [String] {
        guard let indices else { return all }
        return indices.compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    func columnTypes(_ all: [ColumnType]) -> [ColumnType] {
        guard let indices else { return all }
        return indices.compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    func values(_ all: [PluginCellValue]) -> [PluginCellValue] {
        guard let indices else { return all }
        return indices.map { all.indices.contains($0) ? all[$0] : .null }
    }
}
