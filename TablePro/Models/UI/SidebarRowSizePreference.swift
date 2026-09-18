//
//  SidebarRowSizePreference.swift
//  TablePro
//

import AppKit
import SwiftUI

/// How tall the sidebar draws its rows.
///
/// macOS already has this setting, in System Settings > Appearance > Sidebar icon size, and it
/// applies to every app. Following it is the default, so TablePro's sidebar matches Finder, Mail and
/// Notes out of the box. The explicit sizes are an override for a database with hundreds of objects,
/// where density is worth more than matching the rest of the system.
internal enum SidebarRowSizePreference: String, CaseIterable, Codable, Sendable {
    case matchSystem
    case small
    case medium
    case large

    internal var title: String {
        switch self {
        case .matchSystem: return String(localized: "Match System")
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

/// Resolves the preference against the system's own sidebar row size.
///
/// The system value arrives as SwiftUI's `\.sidebarRowSize`, which Apple documents as reflecting the
/// Appearance setting. Being an environment value is the whole point: SwiftUI re-runs anything that
/// reads it when the user changes the setting, so there is no notification to observe and no
/// undocumented defaults key to read.
internal enum SidebarRowSizeResolver {
    internal static func resolve(
        preference: SidebarRowSizePreference,
        system: SidebarRowSize
    ) -> SidebarRowSize {
        switch preference {
        case .matchSystem: return system
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        }
    }

    /// `.default` is what AppKit calls "follow the system", and it is the only value that tracks a
    /// change to the Appearance setting on its own. An override names its size outright.
    internal static func rowSizeStyle(for preference: SidebarRowSizePreference) -> NSTableView.RowSizeStyle {
        switch preference {
        case .matchSystem: return .default
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        }
    }
}

internal extension SidebarRowSize {
    /// The font a row's text takes at each size, so the hosted SwiftUI content grows with the row
    /// AppKit drew rather than staying at one size inside three different heights.
    var rowFont: Font {
        switch self {
        case .small: return .subheadline
        case .medium: return .body
        case .large: return .title3
        @unknown default: return .body
        }
    }

    /// The point size an SF Symbol in a row is drawn at. Paired with `rowFont` so a glyph and the
    /// name beside it stay on the same optical scale.
    var iconPointSize: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 15
        case .large: return 19
        @unknown default: return 15
        }
    }
}
