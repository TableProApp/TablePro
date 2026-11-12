//
//  ObjectIconImage.swift
//  TablePro
//

import AppKit
import SwiftUI

extension ObjectIconTint {
    /// System colors, never a theme slot: an object's hue is identity, which stays system.
    internal var nsColor: NSColor {
        switch self {
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .cyan: return .systemCyan
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .pink: return .systemPink
        case .mint: return .systemMint
        case .brown: return .systemBrown
        }
    }

    internal var color: Color { Color(nsColor: nsColor) }
}

extension ObjectIcon {
    internal var image: Image { Image(systemName: symbolName) }
}

extension View {
    /// Tints an object glyph in its kind's hue, or in `standard`, the color the row drew it in
    /// before the icon style existed. Either one turns to the selected-content color on a prominent
    /// selection. With neither, the glyph keeps the row's own foreground.
    @ViewBuilder
    internal func objectIconTint(_ icon: ObjectIcon, standard: Color? = nil) -> some View {
        if let color = icon.tint?.color ?? standard {
            selectionAwareTint(color)
        } else {
            self
        }
    }
}
