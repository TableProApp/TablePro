//
//  NSRange+translate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/21/25.
//

import Foundation

extension NSRange {
    func translate(location: Int) -> NSRange {
        NSRange(location: self.location + location, length: length)
    }
}
