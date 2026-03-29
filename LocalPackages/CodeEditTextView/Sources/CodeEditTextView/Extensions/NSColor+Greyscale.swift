//
//  NSColor+Greyscale.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/2/24.
//

import AppKit

extension NSColor {
    var grayscale: NSColor {
        guard let color = self.usingColorSpace(.deviceRGB) else { return self }
        // linear relative weights for grayscale: https://en.wikipedia.org/wiki/Grayscale
        let gray = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
        return NSColor(white: gray, alpha: color.alphaComponent)
    }
}
