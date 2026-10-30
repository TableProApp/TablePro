//
//  FavoriteStarButton.swift
//  TablePro
//

import SwiftUI

/// The favorite star every sidebar row uses.
///
/// It is hidden until the row is hovered unless the object is already a favorite, so a list of
/// non-favorites is not a column of grey stars. The button itself is hidden from VoiceOver because
/// a row reads as one element; `FavoriteAccessibilityAction` on the row is what makes it reachable.
internal struct FavoriteStarButton: View {
    internal let isFavorite: Bool
    internal let isRowHovered: Bool
    internal let toggle: () -> Void

    private var isVisible: Bool { isFavorite || isRowHovered }

    // A hidden star is a placeholder, not a button: a button adds AppKit focus views to its row, and the sidebar
    // builds every visible row again on each reload.
    internal var body: some View {
        if isVisible {
            Button(action: toggle) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .regular))
                    .selectionAwareTint(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: Self.side, height: Self.side)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            .help(isFavorite
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites"))
        } else {
            Color.clear
                .frame(width: Self.side, height: Self.side)
                .accessibilityHidden(true)
        }
    }

    private static let side: CGFloat = 20
}

/// A hover-revealed control is pointer-only, so the row publishes the same action to VoiceOver.
internal struct FavoriteAccessibilityAction: ViewModifier {
    internal let isFavorite: Bool
    internal let toggle: (() -> Void)?

    internal func body(content: Content) -> some View {
        if let toggle {
            content.accessibilityAction(
                named: isFavorite
                    ? Text("Remove from Favorites")
                    : Text("Add to Favorites"),
                toggle
            )
        } else {
            content
        }
    }
}
