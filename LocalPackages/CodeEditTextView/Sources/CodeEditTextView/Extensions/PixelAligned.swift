//
//  PixelAligned.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/10/23.
//

import Foundation

public extension NSRect {
    /// Creates a rect pixel-aligned on all edges.
    var pixelAligned: NSRect {
        NSIntegralRectWithOptions(self, .alignAllEdgesNearest)
    }
}

public extension NSPoint {
    /// Creates a point that's pixel-aligned.
    var pixelAligned: NSPoint {
        NSIntegralRectWithOptions(NSRect(x: self.x, y: self.y, width: 0, height: 0), .alignAllEdgesNearest).origin
    }
}
