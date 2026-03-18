//
//  String+NSRange.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 25.05.22.
//

import Foundation

extension String {
    // make string subscriptable with NSRange
    subscript(value: NSRange) -> Substring? {
        let upperBound = String.Index(utf16Offset: Int(value.upperBound), in: self)
        let lowerBound = String.Index(utf16Offset: Int(value.lowerBound), in: self)
        if upperBound <= self.endIndex {
            return self[lowerBound..<upperBound]
        } else {
            return nil
        }
    }
}
