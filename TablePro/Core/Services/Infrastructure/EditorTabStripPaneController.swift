//
//  EditorTabStripPaneController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One connection's tab strip pane: an AppKit view that owns the pointer, wrapped around the
/// SwiftUI view that draws.
///
/// It is a pane like the other three, built and kept alive per connection, so it carries the same
/// `sizingOptions = []` firewall that stops tab content publishing a minimum width the window's
/// split dividers cannot beat (#1872).
///
/// The height is published rather than fixed. A wrapped strip is taller than a scrolling one, and
/// `preferredContentSize` is the documented way for a child to tell its parent so; the titlebar
/// accessory grows the band from it, which is what keeps the content below laid out around the
/// strip instead of behind it.
@MainActor
internal final class EditorTabStripPaneController: NSViewController {
    internal let interaction = EditorTabStripInteraction()

    private let hosting = NSHostingController(rootView: AnyView(Color.clear))

    internal var rootView: AnyView {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    override internal func loadView() {
        let surface = EditorTabInteractionView(interaction: interaction)
        surface.onRowCountChanged = { [weak self] rows in
            self?.publishHeight(forRowCount: rows)
        }
        view = surface

        hosting.sizingOptions = []
        addChild(hosting)
        let pane = hosting.view
        pane.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            pane.topAnchor.constraint(equalTo: surface.topAnchor),
            pane.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        publishHeight(forRowCount: 1)
    }

    /// Empties the pane the way every other one is emptied, including the explicit layout pass a
    /// detached hosting controller needs before SwiftUI will dismantle its tree.
    internal func teardown() {
        interaction.commands = nil
        rootView = AnyView(Color.clear)
        hosting.view.layoutSubtreeIfNeeded()
        view.removeFromSuperview()
        removeFromParent()
    }

    private func publishHeight(forRowCount rows: Int) {
        let height = EditorTabStripLayout.bandHeight(forRowCount: rows)
        guard preferredContentSize.height != height else { return }
        preferredContentSize = CGSize(width: 0, height: height)
    }
}
