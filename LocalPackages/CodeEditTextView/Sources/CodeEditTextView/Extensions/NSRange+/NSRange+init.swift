//
//  NSRange.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/20/24.
//

import Foundation

public extension NSRange {
    @inline(__always)
    init(start: Int, end: Int) {
        self.init(location: start, length: end - start)
    }
}
