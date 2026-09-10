//
//  SidebarHostingCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// A source list cell whose content is a SwiftUI row.
///
/// The hosting view is created once and its root swapped on reuse, so the row keeps its own state
/// instead of being rebuilt on every scroll.
///
/// No emphasis is threaded through: AppKit publishes `backgroundStyle` into the hosted view's
/// environment as `backgroundProminence`, and every semantic foreground reads it, so a selected row
/// switches to the selected-content colour on its own. Only an explicitly tinted glyph needs help,
/// which is what `selectionAwareTint` is for.
internal class SidebarHostingCellView<Row: View>: NSTableCellView {
    private var hosting: NSHostingView<Row>?

    /// The inset between the row's own bounds and its content. Both lists use the same value, which
    /// they did not before: one inset by 2pt and the other by 1pt, so the two tabs of a single
    /// sidebar drew their rows at different heights.
    internal static var contentInset: CGFloat { 1 }

    internal var hostedView: NSView? { hosting }

    internal func update(rootView: Row) {
        if let hosting {
            hosting.rootView = rootView
            applyContentVisibility()
            return
        }
        let view = NSHostingView(rootView: rootView)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentInset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.contentInset),
        ])
        hosting = view
        applyContentVisibility()
    }

    /// Overridden by a cell that can put something else in the row's place, such as a rename field.
    internal func applyContentVisibility() {}

    internal func setHostedContentHidden(_ isHidden: Bool) {
        hosting?.isHidden = isHidden
    }
}
