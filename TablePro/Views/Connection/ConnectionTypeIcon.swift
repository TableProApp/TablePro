//
//  ConnectionTypeIcon.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ConnectionTypeIcon: View {
    private let glyphName: String
    private let isSystemSymbol: Bool
    private let pulses: Bool

    internal init(type: DatabaseType, iconName: String? = nil, pulses: Bool = false) {
        if let symbol = LibraryGlyph.customSymbol(iconName) {
            self.glyphName = symbol
            self.isSystemSymbol = true
        } else {
            self.glyphName = type.iconName
            self.isSystemSymbol = NSImage(systemSymbolName: type.iconName, accessibilityDescription: nil) != nil
        }
        self.pulses = pulses
    }

    internal var body: some View {
        if isSystemSymbol {
            Image(systemName: glyphName)
                .symbolRenderingMode(.hierarchical)
                .pulsingSymbol(isActive: pulses)
        } else {
            Image(glyphName)
                .resizable()
                .scaledToFit()
        }
    }
}
