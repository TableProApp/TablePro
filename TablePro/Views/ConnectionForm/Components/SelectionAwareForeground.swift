//
//  SelectionAwareForeground.swift
//  TablePro
//

import SwiftUI

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
    func selectionAwareForeground(_ standard: Color) -> some View {
        modifier(SelectionAwareForeground(standard: standard))
    }
}
