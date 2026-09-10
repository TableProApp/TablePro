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

    internal var body: some View {
        Button(action: toggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .regular))
                .selectionAwareTint(isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(true)
        .help(isFavorite
            ? String(localized: "Remove from Favorites")
            : String(localized: "Add to Favorites"))
    }
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
