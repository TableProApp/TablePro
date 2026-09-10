//
//  SidebarRowIcon.swift
//  TablePro
//

import SwiftUI

private struct SidebarRowIcon: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content.labelStyle(.titleAndIcon)
        } else {
            content.labelStyle(.titleOnly)
        }
    }
}

extension View {
    func sidebarRowIcon(visible: Bool) -> some View {
        modifier(SidebarRowIcon(isVisible: visible))
    }
}
