//
//  NSEdgeInsets+Equatable.swift
//  CodeEditSourceEditor
//
//  Created by Wouter Hennen on 29/04/2023.
//

import Foundation

extension NSEdgeInsets: @retroactive Equatable {
    public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
        lhs.bottom == rhs.bottom &&
        lhs.top == rhs.top &&
        lhs.left == rhs.left &&
        lhs.right == rhs.right
    }
}
