//
//  ConnectionTypeIcon.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ConnectionTypeIcon: View {
    private let iconName: String
    private let isSystemSymbol: Bool
    private let pulses: Bool

    internal init(type: DatabaseType, pulses: Bool = false) {
        self.iconName = type.iconName
        self.isSystemSymbol = NSImage(systemSymbolName: type.iconName, accessibilityDescription: nil) != nil
        self.pulses = pulses
    }

    internal var body: some View {
        if isSystemSymbol {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating, isActive: pulses)
        } else {
            Image(iconName)
                .resizable()
                .scaledToFit()
        }
    }
}
