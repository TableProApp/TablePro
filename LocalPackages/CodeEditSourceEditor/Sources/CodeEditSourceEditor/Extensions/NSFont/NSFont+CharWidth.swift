//
//  NSFont+CharWidth.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/25/25.
//

import AppKit

extension NSFont {
    var charWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: self]).width
    }
}
