//
//  DatabaseTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts one SwiftUI row. The hosting view is created once and its root swapped on reuse, so the
/// row keeps its own state instead of being rebuilt on every scroll.
///
/// No emphasis is threaded through: AppKit publishes `backgroundStyle` into the hosted view's
/// environment as `backgroundProminence`, and every semantic foreground reads it, so a selected row
/// switches to the selected-content colour on its own. Only an explicitly tinted glyph needs help,
/// which is what `selectionAwareTint` is for. Threading a Bool instead cost a full SwiftUI root swap
/// on every visible row every time the selection moved.
final class DatabaseTreeCellView: NSTableCellView {
    private var hosting: NSHostingView<DatabaseTreeRowView>?

    func configure(node: DatabaseTreeNode, context: DatabaseTreeRowContext, actions: DatabaseTreeRowActions) {
        let rootView = DatabaseTreeRowView(node: node, context: context, actions: actions)
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
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
        hosting = view
    }
}
