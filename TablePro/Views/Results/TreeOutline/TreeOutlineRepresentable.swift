//
//  TreeOutlineRepresentable.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Not a SwiftUI `List`: `.textSelection` there takes every click, so a row never selects, and as
/// this app hosts it a `List` does not take the keyboard on a click.
internal struct TreeOutlineRepresentable<Node: FilterableTreeNode>: NSViewRepresentable {
    /// Observed so a font change runs `updateNSView`.
    @ObservedObject private var themeEngine = ThemeEngine.shared

    private let content: TreeOutlineContent<Node>
    private let cache: TreeProjectionCache<Node>
    private let onSetExpanded: (TreeNodePath, Bool) -> Void
    private let onExpandAll: () -> Void
    private let onCollapseAll: () -> Void

    internal init(
        content: TreeOutlineContent<Node>,
        cache: TreeProjectionCache<Node>,
        onSetExpanded: @escaping (TreeNodePath, Bool) -> Void,
        onExpandAll: @escaping () -> Void,
        onCollapseAll: @escaping () -> Void
    ) {
        self.content = content
        self.cache = cache
        self.onSetExpanded = onSetExpanded
        self.onExpandAll = onExpandAll
        self.onCollapseAll = onCollapseAll
    }

    internal func makeCoordinator() -> TreeOutlineCoordinator<Node> {
        TreeOutlineCoordinator(cache: cache)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = TreeOutlineView.make()
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        context.coordinator.attach(outlineView)
        update(context.coordinator)
        return scrollView
    }

    internal func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: TreeOutlineCoordinator<Node>) {
        coordinator.onSetExpanded = onSetExpanded
        coordinator.onExpandAll = onExpandAll
        coordinator.onCollapseAll = onCollapseAll
        coordinator.apply(
            content,
            fonts: TreeOutlineFonts(value: themeEngine.valueFont, key: themeEngine.dataGridFonts.medium)
        )
    }
}
