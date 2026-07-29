//
//  DatabaseTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

final class DatabaseTreeCellView: NSTableCellView {
    private var hosting: NSHostingView<DatabaseTreeRowView>?
    private var node: DatabaseTreeNode?
    private var rowContext: DatabaseTreeRowContext?
    private var actions: DatabaseTreeRowActions?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { rebuild() }
    }

    func configure(node: DatabaseTreeNode, context: DatabaseTreeRowContext, actions: DatabaseTreeRowActions) {
        self.node = node
        self.rowContext = context
        self.actions = actions
        rebuild()
    }

    private func rebuild() {
        guard let node, let rowContext, let actions else { return }
        let rootView = DatabaseTreeRowView(
            node: node,
            isEmphasized: backgroundStyle == .emphasized,
            context: rowContext,
            actions: actions
        )
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
            view.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        hosting = view
    }
}
