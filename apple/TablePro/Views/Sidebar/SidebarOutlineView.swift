//
//  SidebarOutlineView.swift
//  TablePro
//

import AppKit

// The focus contract every sidebar list shares: take the keyboard on click, and fill a window nobody holds yet.
internal class SidebarOutlineView: NSOutlineView {
    // NSTableView's own promotion on click intermittently left the filter field holding the keyboard.
    override internal func mouseDown(with event: NSEvent) {
        claimFirstResponder()
        super.mouseDown(with: event)
    }

    override internal func keyDown(with event: NSEvent) {
        guard !interpretCommandKey(event) else { return }
        super.keyDown(with: event)
    }

    // NSTableView stops observing the window's first responder for the whole of its move into a window, so focus
    // taken in here leaves every row unemphasized (grey) until the window's key state next changes.
    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.adoptFirstResponderIfVacant()
        }
    }

    private func claimFirstResponder() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    // AppKit fills a vacant window only when it is first placed on screen, before SwiftUI has built this list.
    // A hidden list never takes it: a collapsed sidebar would open tables the user cannot see.
    private func adoptFirstResponderIfVacant() {
        guard let window, window.firstResponder === window, !isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(self)
    }
}
