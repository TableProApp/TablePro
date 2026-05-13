//
//  SidebarTint.swift
//  TablePro
//

import SwiftUI

private struct SidebarTint: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(backgroundProminence == .increased ? Color.white : color)
    }
}

extension View {
    func sidebarTint(_ color: Color) -> some View {
        modifier(SidebarTint(color: color))
    }
}
