//
//  SelectionAwareForeground.swift
//  TablePro
//

import SwiftUI

private struct SelectionAwareForeground: ViewModifier {
    let standard: Color
    let emphasizedOpacity: Double
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(resolvedStyle)
    }

    private var resolvedStyle: Color {
        guard backgroundProminence == .increased else {
            return standard
        }
        return Color(nsColor: .alternateSelectedControlTextColor).opacity(emphasizedOpacity)
    }
}

extension View {
    func selectionAwareForeground(_ standard: Color, emphasizedOpacity: Double = 1) -> some View {
        modifier(SelectionAwareForeground(standard: standard, emphasizedOpacity: emphasizedOpacity))
    }
}
