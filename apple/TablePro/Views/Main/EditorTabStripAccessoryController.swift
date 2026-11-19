//
//  EditorTabStripAccessoryController.swift
//  TablePro
//

import AppKit

// A bottom titlebar accessory is where the system hosts its own tab bar, and AppKit insets it past the sidebar.
@MainActor
internal final class EditorTabStripAccessoryController: NSTitlebarAccessoryViewController {
    private let paneHost = WorkspacePaneHost()

    internal init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        automaticallyAdjustsSize = false
        // Zero would hide the strip whenever full screen hides the menu bar.
        fullScreenMinHeight = EditorTabStripLayout.bandHeight
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("EditorTabStripAccessoryController does not support NSCoder init")
    }

    override internal func loadView() {
        let band = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: EditorTabStripLayout.bandHeight))
        view = band

        addChild(paneHost)
        let hosted = paneHost.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: band.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: band.bottomAnchor),
        ])
    }

    internal func show(_ controller: NSViewController?) {
        paneHost.show(controller)
    }

    // Collapsing keeps every connection's strip built while the window shows a pane with no tabs.
    internal func setBandVisible(_ isVisible: Bool) {
        guard isHidden == isVisible else { return }
        if !isVisible {
            // Ended by the strip, which gives focus back to where the edit took it from rather than to the window.
            (paneHost.shown as? EditorTabStripPaneController)?.stripView.endRename(commit: true)
            resignFirstResponderInsideBand()
        }
        isHidden = !isVisible
    }

    private func resignFirstResponderInsideBand() {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: view)
        else { return }
        window.makeFirstResponder(nil)
    }
}
