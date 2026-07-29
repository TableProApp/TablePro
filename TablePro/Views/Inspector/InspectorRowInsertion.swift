//
//  InspectorRowInsertion.swift
//  TablePro
//

import Foundation

enum InspectorRowInsertion {
    static func storeIndex(anchorDisplayRow: Int?, below: Bool, displayToStore: [Int], rowCount: Int) -> Int {
        guard let displayRow = anchorDisplayRow,
              displayRow >= 0, displayRow < displayToStore.count else {
            return below ? rowCount : 0
        }
        let storeRow = displayToStore[displayRow]
        return below ? storeRow + 1 : storeRow
    }
}
