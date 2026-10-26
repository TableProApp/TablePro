//
//  ToolbarSymbols.swift
//  TablePro
//

import Foundation

/// The glyphs a toolbar draws for the actions every toolbar shares, in both apps.
///
/// From macOS 26 and iOS 26 a toolbar item sits in its own glass container, and the HIG asks for
/// symbols without borders there: the container is the border, so a circled glyph draws two.
/// Earlier releases give an item no container, and the circled form is the one their own toolbars
/// use. Each answer is a function of that one fact, so both forms can be tested on either release.
nonisolated internal enum ToolbarSymbols {
    internal static let commit = "checkmark"

    internal static var itemsHaveContainer: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return true
        }
        return false
    }

    internal static func more(itemsHaveContainer: Bool = ToolbarSymbols.itemsHaveContainer) -> String {
        itemsHaveContainer ? "ellipsis" : "ellipsis.circle"
    }

    /// A More control inside a container draws no menu indicator, measured on Finder and Notes.
    /// Every other pull-down keeps the system's.
    internal static func moreShowsIndicator(itemsHaveContainer: Bool = ToolbarSymbols.itemsHaveContainer) -> Bool {
        !itemsHaveContainer
    }

    /// The filled disc is state, a filter narrowing the list, so it stays where the idle border goes.
    internal static func filter(
        isActive: Bool = false,
        itemsHaveContainer: Bool = ToolbarSymbols.itemsHaveContainer
    ) -> String {
        if isActive {
            return "line.3.horizontal.decrease.circle.fill"
        }
        return itemsHaveContainer ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle"
    }

    /// The filled disc is state, a sort in effect, as it is for the filter.
    internal static func sort(
        isActive: Bool = false,
        itemsHaveContainer: Bool = ToolbarSymbols.itemsHaveContainer
    ) -> String {
        if isActive {
            return "arrow.up.arrow.down.circle.fill"
        }
        return itemsHaveContainer ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle"
    }

    internal static func disconnect(itemsHaveContainer: Bool = ToolbarSymbols.itemsHaveContainer) -> String {
        itemsHaveContainer ? "xmark" : "xmark.circle"
    }
}
