//
//  GlobalScopeBadge.swift
//  TablePro
//

import SwiftUI

/// The mark a Favorites row carries when its record belongs to every connection rather than the one
/// on screen. A saved query and a folder both have a scope now, so both say it the same way.
internal struct GlobalScopeBadge: View {
    internal static var accessibilityDescription: String { String(localized: "global") }

    internal var body: some View {
        Image(systemName: "globe")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
