//
//  NSFont+LineHeight.swift
//  TableProEditorKit
//
//  Created by Lukas Pistrol on 28.05.22.
//

import AppKit
import TableProTextEngine

public extension NSFont {
    /// The default line height of the font.
    var lineHeight: Double {
        NSLayoutManager().defaultLineHeight(for: self)
    }
}
