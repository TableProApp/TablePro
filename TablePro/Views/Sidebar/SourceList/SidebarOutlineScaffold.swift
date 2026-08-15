//
//  SidebarOutlineScaffold.swift
//  TablePro
//

import AppKit

/// The AppKit configuration both sidebar lists need, stated once.
///
/// The two lists had drifted apart on exactly the settings nobody looks at twice: one autohid its
/// scrollers and the other did not, one cleared its background and the other did not. Everything
/// here is either an AppKit default a source list wants or a value the caller supplies, so a third
/// list cannot drift again.
@MainActor
internal enum SidebarOutlineScaffold {
    internal struct Configuration {
        internal let columnIdentifier: String
        internal let allowsMultipleSelection: Bool
        internal let rowSizePreference: SidebarRowSizePreference
    }

    internal static func makeScrollView(
        outlineView: NSOutlineView,
        configuration: Configuration
    ) -> NSScrollView {
        configure(outlineView, with: configuration)

        /// No `scrollerStyle`: it is the user's "Show scroll bars" setting in General settings, and
        /// `NSScrollView` already follows it.
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    private static func configure(_ outlineView: NSOutlineView, with configuration: Configuration) {
        outlineView.headerView = nil
        outlineView.style = .sourceList
        /// `.sourceList` already supplies the row height and the indent per level, and `.default`
        /// is how a table says "the size the user picked in Appearance".
        outlineView.rowSizeStyle = SidebarRowSizeResolver.rowSizeStyle(for: configuration.rowSizePreference)
        outlineView.allowsMultipleSelection = configuration.allowsMultipleSelection
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        /// Expansion is per connection, and while a filter is active it is the search's rather than
        /// the user's, neither of which AppKit's single global autosave record can express.
        outlineView.autosaveExpandedItems = false
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(configuration.columnIdentifier))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    /// Re-applies the one setting that can change while the list is on screen, because the user can
    /// change the system sidebar size or the app's override without the list being rebuilt.
    internal static func applyRowSize(
        _ preference: SidebarRowSizePreference,
        to scrollView: NSScrollView
    ) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        let style = SidebarRowSizeResolver.rowSizeStyle(for: preference)
        guard outlineView.rowSizeStyle != style else { return }
        outlineView.rowSizeStyle = style
    }
}
