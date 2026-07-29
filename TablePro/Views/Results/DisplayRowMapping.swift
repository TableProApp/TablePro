//
//  DisplayRowMapping.swift
//  TablePro
//

import Foundation

enum DisplayRowMapping {
    static func rowIndex(forDisplay displayIndex: Int, displayIDs: [RowID]?, in tableRows: TableRows) -> Int? {
        guard let displayIDs else {
            guard displayIndex >= 0, displayIndex < tableRows.count else { return nil }
            return displayIndex
        }
        guard displayIndex >= 0, displayIndex < displayIDs.count else { return nil }
        return tableRows.index(of: displayIDs[displayIndex])
    }

    static func row(forDisplay displayIndex: Int, displayIDs: [RowID]?, in tableRows: TableRows) -> Row? {
        guard let index = rowIndex(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows) else { return nil }
        return tableRows.rows[index]
    }
}
