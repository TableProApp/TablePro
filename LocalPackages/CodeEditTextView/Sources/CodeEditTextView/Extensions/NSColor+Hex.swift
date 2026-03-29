//
//  NSColor+Hex.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 27.11.24.
//

import AppKit

extension NSColor {
    convenience init(hex: Int, alpha: Double = 1.0) {
        let red = (hex >> 16) & 0xFF
        let green = (hex >> 8) & 0xFF
        let blue = hex & 0xFF
        self.init(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
    }
}
