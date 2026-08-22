//
//  ToolbarSwitcherPresenter.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Presents the connection and database switchers for one connection, from the command that opens
/// them rather than from a view inside a toolbar item.
///
/// The switchers used to be `.popover(isPresented:)` on a SwiftUI view mounted as the connection
/// group's hosted content, with the command only flipping a flag. AppKit clips a toolbar item into
/// the overflow menu when the window is narrow, and `NSToolbarItem`'s contract is that a clipped
/// item remains reachable through its `menuFormRepresentation`, never through its view. So the view
/// was not on screen, nothing observed the flag, and Switch Connection did nothing at all: no
/// popover, no error. The same held after Customize Toolbar removed the item, at any window width,
/// which is why the HIG says a toolbar "can't be the only place that presents a command".
///
/// Two surfaces, chosen by whether an anchor exists:
/// - The item is in a visible toolbar: an `NSPopover` anchored to it, which is the macOS idiom for
///   a toolbar control that reveals a chooser. A clipped item still resolves, and AppKit presents it
///   "from another appropriate affordance in the window" itself.
/// - No anchor: the same content in the floating panel Open Quickly already uses, which belongs to
///   the window rather than to the toolbar.
@MainActor
internal final class ToolbarSwitcherPresenter {
    private var popover: NSPopover?
    /// The window's one floating panel, passed in rather than built here. `MainContentCoordinator`
    /// already owns a `QuickSwitcherPanelController` for Open Quickly, and a second one would give a
    /// window two independent panels centred on the same point, neither able to see or dismiss the
    /// other.
    private let panelController: QuickSwitcherPanelController
    private var closeObserver: (any NSObjectProtocol)?

    internal init(panelController: QuickSwitcherPanelController) {
        self.panelController = panelController
    }

    internal var isPresenting: Bool {
        popover?.isShown == true || panelController.isPresented
    }

    /// `anchoredTo` is an identifier rather than an item because the item has to be resolved at
    /// presentation time: the toolbar rebuilds, and an item the user removed is simply absent.
    ///
    /// Invoking the command while the switcher is up closes it, matching `showQuickSwitcher()` and
    /// the toggle the toolbar button used to give for free. Without it a second press would tear the
    /// surface down and rebuild it with empty `@State`, losing whatever the user had typed.
    internal func present(
        from window: NSWindow?,
        anchoredTo identifier: NSToolbarItem.Identifier,
        contentSize: NSSize,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> some View
    ) {
        guard !isPresenting else {
            dismiss()
            return
        }

        if let item = Self.anchor(in: window, identifier) {
            /// `.transient`, not `PopoverPresenter`'s `.semitransient` default: a semitransient
            /// popover ignores interaction outside its own window, so moving to another window or
            /// another app would leave the chooser floating over a window it no longer belongs to.
            /// The SwiftUI popover this replaces closed on any outside interaction.
            let shown = PopoverPresenter.show(
                relativeTo: item,
                contentSize: contentSize,
                behavior: .transient,
                content: content
            )
            popover = shown
            /// AppKit closes a transient popover by itself and nothing else reports it. Without this
            /// the presenter holds a closed popover, and through it the hosting controller, the
            /// SwiftUI tree and the switcher's loaded container list, until the next presentation.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSPopover.didCloseNotification,
                object: shown,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetPopover() }
            }
            return
        }

        /// The panel paints no background of its own: it is borderless, clear and corner-masked, and
        /// the surface material belongs to its content, the way `QuickSwitcherPanelView` supplies
        /// it. Without this the switcher floats as unbacked text with its corners cut off.
        let dismissPanel: () -> Void = { [weak self] in self?.panelController.dismiss() }
        panelController.present(
            content(dismissPanel).quickSwitcherSurface(cornerRadius: QuickSwitcherMetrics.cornerRadius),
            over: window
        )
    }

    internal func dismiss() {
        popover?.performClose(nil)
        forgetPopover()
        panelController.dismiss()
    }

    private func forgetPopover() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        popover = nil
    }

    /// A hidden toolbar is treated as no anchor at all. `toggleToolbarShown` only flips
    /// `NSToolbar.isVisible` and leaves the items in place, so the item still resolves and AppKit
    /// documents nothing about what anchoring to it then does. Since the failure mode of guessing
    /// wrong is an `NSInvalidArgumentException` that Swift cannot catch, this takes the branch it
    /// can reason about instead of the one it would have to measure.
    internal static func anchor(
        in window: NSWindow?,
        _ identifier: NSToolbarItem.Identifier
    ) -> NSToolbarItem? {
        guard let toolbar = window?.toolbar, toolbar.isVisible else { return nil }
        return toolbar.items.first { $0.itemIdentifier == identifier }
    }
}
