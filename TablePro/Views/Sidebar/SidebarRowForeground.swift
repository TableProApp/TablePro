//
//  SidebarRowForeground.swift
//  TablePro
//

import SwiftUI

internal enum SidebarRowForeground {
    internal enum Role: Equatable {
        case active
        case system
        case normal
    }

    internal static func role(isActive: Bool, isSystem: Bool) -> Role {
        if isActive { return .active }
        if isSystem { return .system }
        return .normal
    }
}

/// Emphasis is not a role. AppKit publishes the row's background prominence into the hosted view,
/// and `.primary` and `.secondary` both answer it on their own, so only the active-object tint needs
/// resolving: an accent label on an accent fill reads as unselected.
private struct SidebarRowForegroundModifier: ViewModifier {
    let role: SidebarRowForeground.Role

    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        content.foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        switch role {
        case .active:
            return AnyShapeStyle(
                SelectionAwareTintResolver.color(standard: Color.accentColor, prominence: backgroundProminence)
            )
        case .system:
            return AnyShapeStyle(.secondary)
        case .normal:
            return AnyShapeStyle(.primary)
        }
    }
}

internal extension View {
    func sidebarRowForeground(isActive: Bool, isSystem: Bool) -> some View {
        modifier(SidebarRowForegroundModifier(role: SidebarRowForeground.role(isActive: isActive, isSystem: isSystem)))
    }
}
