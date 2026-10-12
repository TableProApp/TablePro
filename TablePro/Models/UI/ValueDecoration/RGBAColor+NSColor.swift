//
//  RGBAColor+NSColor.swift
//  TablePro
//

import AppKit

internal extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
