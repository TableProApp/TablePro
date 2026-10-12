//
//  NSRange+TSRange.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 2/26/23.
//

import Foundation
import SwiftTreeSitter

extension NSRange {
    var tsRange: TSRange {
        TSRange(
            points: .zero..<(.zero),
            bytes: (UInt32(self.location) * 2)..<(UInt32(self.location + self.length) * 2)
        )
    }
}
