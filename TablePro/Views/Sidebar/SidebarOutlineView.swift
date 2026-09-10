//
//  SidebarOutlineView.swift
//  TablePro
//

import AppKit

/// The focus contract both sidebar lists need, stated once.
///
/// AppKit expects a view that can hold the keyboard to say so when it is clicked, which is why the
/// data grid's table view opens `mouseDown` with exactly this line (`KeyHandlingTableView`). The
/// sidebar lists were leaving it to `NSTableView`'s own promotion, and in the running app that
/// intermittently did not happen: the click moved the selection while the filter field kept the
/// keyboard, so the row drew unemphasized and the arrow keys went to the field rather than the list.
///
/// Painting the row emphasized instead would be a lie, because the keyboard really was elsewhere.
/// `FieldDrivenList` may force emphasis on because its table refuses focus by design and its search
/// field forwards the keys; these lists are meant to hold focus, so they take it.
internal class SidebarOutlineView: NSOutlineView {
    override internal func mouseDown(with event: NSEvent) {
        claimFirstResponder()
        super.mouseDown(with: event)
    }

    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adoptFirstResponderIfVacant()
    }

    private func claimFirstResponder() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// A window whose `firstResponder` is the window itself has nobody to hand a key event to, so
    /// every keystroke beeps and every list draws its selection unemphasized.
    ///
    /// AppKit fills that vacancy when a window is first placed on screen, from
    /// `initialFirstResponder` or the key view loop. Neither can reach a list SwiftUI has not built
    /// yet, so the vacancy outlives the only chance AppKit had to fill it. Only the vacancy is
    /// taken: a window that already has a first responder keeps it.
    private func adoptFirstResponderIfVacant() {
        guard let window, window.firstResponder === window else { return }
        window.makeFirstResponder(self)
    }
}
