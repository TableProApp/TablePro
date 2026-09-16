//
//  SelectionAwareForeground.swift
//  TablePro
//

import SwiftUI

@available(macOS 14.0, *)
private struct SelectionAwareForeground: ViewModifier {
    let standard: Color
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(
            backgroundProminence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(standard)
        )
    }
}

extension View {
    /// `backgroundProminence` is macOS 14; before it the standard colour is the only answer.
    @ViewBuilder
    func selectionAwareForeground(_ standard: Color) -> some View {
        if #available(macOS 14.0, *) {
            modifier(SelectionAwareForeground(standard: standard))
        } else {
            foregroundStyle(standard)
        }
    }
}
