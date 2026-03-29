//
//  NSRange+isEmpty.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/23/23.
//

import Foundation

public extension NSRange {
    var isEmpty: Bool {
        length == 0
    }
}
