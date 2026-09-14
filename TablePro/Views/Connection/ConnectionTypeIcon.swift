//
//  ConnectionTypeIcon.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ConnectionTypeIcon: View {
    private let iconName: String
    private let isSystemSymbol: Bool
    private let size: CGFloat?
    private let pulses: Bool

    /// `size` is left out where the container sizes the icon itself, which is what
    /// `ContentUnavailableView` does to the view in its label's icon slot.
    internal init(type: DatabaseType, size: CGFloat? = nil, pulses: Bool = false) {
        self.iconName = type.iconName
        self.isSystemSymbol = NSImage(systemSymbolName: type.iconName, accessibilityDescription: nil) != nil
        self.size = size
        self.pulses = pulses
    }

    internal var body: some View {
        Group {
            if isSystemSymbol {
                Image(systemName: iconName)
                    .symbolRenderingMode(.hierarchical)
                    .font(size.map { Font.system(size: ConnectionIconMetrics.symbolPoints($0)) })
                    .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            } else {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}
