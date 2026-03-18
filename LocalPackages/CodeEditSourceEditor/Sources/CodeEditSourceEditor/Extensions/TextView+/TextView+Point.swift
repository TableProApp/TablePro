//
//  TextView+Point.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/18/24.
//

import Foundation
import CodeEditTextView
import SwiftTreeSitter

extension TextView {
    func pointForLocation(_ location: Int) -> Point? {
        guard let linePosition = layoutManager.textLineForOffset(location) else { return nil }
        let column = location - linePosition.range.location
        return Point(row: linePosition.index, column: column)
    }
}
