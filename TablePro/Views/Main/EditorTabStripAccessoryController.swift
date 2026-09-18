//
//  EditorTabStripAccessoryController.swift
//  TablePro
//

import AppKit

/// The window chrome band that holds the editor tab strip, in the same place the system puts its
/// own: a bottom titlebar accessory, flush under the toolbar.
///
/// This is not a styling choice. A runtime probe of `NSTabBar`, the private control Finder's tab
/// bar is built from, shows it hosted in exactly this way, and AppKit gives the placement two
/// things a content-view mount cannot have. The accessory is inset past a `.sidebar` split item
/// automatically, so the band starts where the content pane starts rather than at the window edge,
/// with no sidebar-width tracking of our own. And the window's `contentLayoutRect` shrinks by the
/// band, so the content below is laid out around it instead of being pushed by a stack.
///
/// Three properties have to be set together or the band misbehaves in ways that only show up in
/// one state. `automaticallyAdjustsSize` defaults to true and would resize the view to the
/// system's standard accessory height, discarding ours. `fullScreenMinHeight` defaults to zero,
/// and the header is explicit that zero "will fully hide the view when the menu bar is hidden", so
/// leaving it would make the tab strip vanish in full screen. `layoutAttribute` must be `.bottom`
/// for either of the other two to apply at all.
@MainActor
internal final class EditorTabStripAccessoryController: NSTitlebarAccessoryViewController {
    /// The strip belongs to one connection, the accessory belongs to the window, and a window
    /// hosts several connections. The band therefore shows the selected workspace's own strip the
    /// same way the split items show its panes, so every other connection's strip stays built.
    private let paneHost = WorkspacePaneHost()

    /// The band's height, which follows the strip. A wrapped strip is taller than a scrolling one,
    /// and the accessory has to grow with it or the extra rows are drawn behind the content
    /// instead of the window's `contentLayoutRect` making room for them.
    ///
    /// It is the view's own frame height, never a constraint.
    /// `NSTitlebarAccessoryViewController` places its view itself and observes that height for
    /// changes, which is what the width comment below already says.
    private var bandHeight = EditorTabStripLayout.bandHeight

    internal init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        automaticallyAdjustsSize = false
        fullScreenMinHeight = EditorTabStripLayout.bandHeight
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("EditorTabStripAccessoryController does not support NSCoder init")
    }

    /// The width is a placeholder AppKit replaces with the pane's; only the height is ours, and
    /// `NSTitlebarAccessoryViewController` observes it for changes.
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
        applyBandHeight(paneHost.preferredContentSize.height)
    }

    /// The strip publishes its height through `preferredContentSize`, the documented way for a
    /// child to ask its parent for room, and `WorkspacePaneHost` passes it on from the pane it is
    /// showing. Anything at or below zero means the pane has nothing to say yet, so the band keeps
    /// the single-row height it was built with.
    override internal func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === paneHost else { return }
        applyBandHeight(viewController.preferredContentSize.height)
    }

    private func applyBandHeight(_ height: CGFloat) {
        let resolved = height > 0 ? height : EditorTabStripLayout.bandHeight
        guard bandHeight != resolved else { return }
        bandHeight = resolved
        fullScreenMinHeight = resolved
        view.frame.size.height = resolved
    }

    /// `hidden` collapses the band to zero height without taking it off the window, which is what
    /// keeps a connection's strip built while the window shows a pane that has no tabs to list.
    ///
    /// The band collapses under whatever had keyboard focus, so focus is let go on the way down.
    /// Closing the second-to-last tab from the strip is enough to reach this: the button that was
    /// clicked is inside the band that is now zero points tall, and a first responder in a view
    /// with no size leaves Full Keyboard Access tabbing out of somewhere invisible.
    internal func setBandVisible(_ isVisible: Bool) {
        guard isHidden == isVisible else { return }
        if !isVisible { resignFirstResponderInsideBand() }
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
