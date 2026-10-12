//
//  SelectionAwareTint.swift
//  TablePro
//

import SwiftUI

/// Content drawn on a prominent selection fill has to switch to the selected-content
/// colour, the way `NSColor.alternateSelectedControlTextColor` does in AppKit. A tint
/// left at the accent colour renders accent-on-accent and disappears.
enum SelectionAwareTintResolver {
    @available(macOS 14.0, *)
    static func color(standard: Color, prominence: BackgroundProminence) -> Color {
        color(standard: standard, isProminent: prominence == .increased)
    }

    /// The prominence-free form, so the rule stays testable where `BackgroundProminence`
    /// (macOS 14) cannot be named.
    static func color(standard: Color, isProminent: Bool) -> Color {
        isProminent ? .emphasizedSelectionLabel : standard
    }
}

@available(macOS 14.0, *)
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
    /// `backgroundProminence` is macOS 14. Before it, a prominent selection could not be
    /// detected from SwiftUI at all, so the tint stays at its standard colour.
    @ViewBuilder
    func selectionAwareTint(_ color: Color) -> some View {
        if #available(macOS 14.0, *) {
            modifier(SelectionAwareTint(standard: color))
        } else {
            foregroundStyle(color)
        }
    }
}
