//
//  SelectionAwareTint.swift
//  TablePro
//

import SwiftUI

/// Content drawn on a prominent selection fill has to switch to the selected-content
/// colour, the way `NSColor.alternateSelectedControlTextColor` does in AppKit. A tint
/// left at the accent colour renders accent-on-accent and disappears.
enum SelectionAwareTintResolver {
    static func color(standard: Color, prominence: BackgroundProminence) -> Color {
        prominence == .increased ? .emphasizedSelectionLabel : standard
    }
}

private struct SelectionAwareTint: ViewModifier {
    let standard: Color
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(
            SelectionAwareTintResolver.color(standard: standard, prominence: backgroundProminence)
        )
    }
}

extension View {
    /// Tints content with `color`, switching to the selected-content colour when the view
    /// sits on a prominent selection background.
    func selectionAwareTint(_ color: Color) -> some View {
        modifier(SelectionAwareTint(standard: color))
    }
}
