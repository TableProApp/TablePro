//
//  SidebarRowForeground.swift
//  TablePro
//

import SwiftUI

internal enum SidebarRowForeground {
    internal enum Role: Equatable {
        case emphasized
        case active
        case system
        case normal
    }

    /// Emphasis outranks the active-object tint. A tinted label on an emphasized fill reads as
    /// unselected, so the marker has to give way to legibility while the row is selected.
    internal static func role(isEmphasized: Bool, isActive: Bool, isSystem: Bool) -> Role {
        if isEmphasized { return .emphasized }
        if isActive { return .active }
        if isSystem { return .system }
        return .normal
    }

    internal static func style(for role: Role) -> AnyShapeStyle {
        switch role {
        case .emphasized: return AnyShapeStyle(Color.emphasizedSelectionLabel)
        case .active: return AnyShapeStyle(.tint)
        case .system: return AnyShapeStyle(.secondary)
        case .normal: return AnyShapeStyle(.primary)
        }
    }
}
