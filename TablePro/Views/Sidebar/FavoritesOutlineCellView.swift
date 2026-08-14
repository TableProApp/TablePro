//
//  FavoritesOutlineCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts one SwiftUI row. The hosting view is created once and its root swapped on reuse, so the
/// row keeps its own state instead of being rebuilt on every scroll.
///
/// No emphasis is threaded through: AppKit publishes `backgroundStyle` into the hosted view's
/// environment as `backgroundProminence`, which is what the row content already reads.
internal final class FavoritesOutlineCellView<Row: View>: NSTableCellView {
    private var hosting: NSHostingView<Row>?

    internal func update(rootView: Row) {
        if let hosting {
            hosting.rootView = rootView
            return
        }
        let view = NSHostingView(rootView: rootView)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        hosting = view
    }
}
