//
//  ConnectionEditorViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

// The window's content: the split view on top and the commit bar across its full width, so the sidebar
// material ends at the bar. `NSWindow(contentViewController:)` binds the window title to this controller's.
@MainActor
final class ConnectionEditorViewController: NSViewController {
    let split: ConnectionEditorSplitViewController
    let commitBar: NSHostingView<ConnectionEditorCommitBar>

    init(store: ConnectionEditorStore, actions: ConnectionEditorCommitActions, onCloseMissingRecord: @escaping () -> Void) {
        split = ConnectionEditorSplitViewController(store: store, onCloseMissingRecord: onCloseMissingRecord)
        commitBar = NSHostingView(rootView: ConnectionEditorCommitBar(store: store, actions: actions))
        super.init(nibName: nil, bundle: nil)
        // Before the window exists, so its title is never blank.
        title = store.windowTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorViewController does not support NSCoder init")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(
            origin: .zero,
            size: ConnectionEditorWindowFrame.defaultContentSize(visibleHeight: NSScreen.main?.visibleFrame.height ?? 800)
        ))
        addChild(split)
        // The bar's height follows its content, and its width never pins the window.
        commitBar.sizingOptions = [.intrinsicContentSize]
        commitBar.setContentHuggingPriority(.required, for: .vertical)
        commitBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commitBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for subview in [split.view, commitBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: commitBar.topAnchor),
            commitBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commitBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commitBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
