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
///   "from another appropriate affordance in the window" itself: measured on macOS 27 at a 420pt
///   window, both centred items anchored on the clipped-items indicator, a 36pt square, and neither
///   raised.
/// - No anchor: the same content in the floating panel Open Quickly already uses, which belongs to
///   the window rather than to the toolbar.
@MainActor
internal final class ToolbarSwitcherPresenter {
    /// Which chooser is up, so a second press of the same command closes it while the other
    /// command replaces it.
    internal enum Subject: Equatable {
        case connection
        case container(ContainerSwitchTarget?)
    }

    private var presentedSubject: Subject?
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
    /// Invoking the same command while its switcher is up closes it, matching `showQuickSwitcher()`
    /// and the toggle the toolbar button used to give for free. Without it a second press would
    /// tear the surface down and rebuild it with empty `@State`, losing whatever the user had
    /// typed.
    ///
    /// `subject` is what makes "the same command" answerable. One presenter serves the connection
    /// chooser and the container chooser, so an identity check on presentation alone would make
    /// either command close the other rather than replace it.
    ///
    /// `hiddenBy` is the toolbar's own record of what it took out of the titlebar, forwarded to
    /// `anchor(in:_:hiddenBy:)`.
    internal func present(
        from window: NSWindow?,
        anchoredTo identifier: NSToolbarItem.Identifier,
        hiddenBy visibility: ToolbarVisibility?,
        subject: Subject,
        contentSize: NSSize,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> some View
    ) {
        if isPresenting {
            let wasShowing = presentedSubject
            dismiss()
            guard wasShowing != subject else { return }
        }
        presentedSubject = subject

        if let item = Self.anchor(in: window, identifier, hiddenBy: visibility) {
            /// `.transient`, not `PopoverPresenter`'s `.semitransient` default: a semitransient
            /// popover ignores interaction outside its own window, so moving to another window or
            /// another app would leave the chooser floating over a window it no longer belongs to.
            /// The SwiftUI popover this replaces closed on any outside interaction.
            let shown = PopoverPresenter.show(
                relativeTo: item,
                in: window,
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
        presentedSubject = nil
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

    /// The toolbar item a chooser presents from, or nil for the floating panel.
    ///
    /// It asks AppKit nothing about what is on screen, because nothing AppKit answers is safe to
    /// act on. Measured on macOS 27, one visit to Customize Toolbar leaves `NSToolbar.visibleItems`
    /// and `NSToolbarItem.isVisible` over-reporting for good, the item's `view` is nil for every
    /// native item, and the titlebar's view hierarchy keeps a stale run of item viewers behind. So
    /// the question splits in two, and neither half is a visibility reading.
    ///
    /// Whether the item is reachable is the app's own record: an item the resolver hid answers nil,
    /// and the chooser takes the floating panel rather than a popover anchored on nothing, which
    /// AppKit would place at the centre of the window. Which instance to anchor on is
    /// `NSToolbar.items`, measured correct through every palette visit, down to each item's
    /// identity. An item the user removed is absent from it, and answers nil the same way.
    ///
    /// A clipped item is neither, and needs no answer: every item here is a top-level item, and
    /// AppKit anchors a clipped top-level item on the clipped-items indicator by itself. Only a
    /// subitem of a group that was off screen ever raised, and there are no subitems left to anchor
    /// on.
    ///
    /// `hiddenBy` has no default. Nil is a real answer, a toolbar with no resolver that hides
    /// nothing, and a caller has to say so rather than get it by omission.
    ///
    /// A hidden toolbar is treated as no anchor at all. `toggleToolbarShown` only flips
    /// `NSToolbar.isVisible` and leaves the items in place, so the item still resolves and AppKit
    /// documents nothing about what anchoring to it then does. That property belongs to the toolbar
    /// rather than to an item, and it is measured to read correctly after a palette visit.
    internal static func anchor(
        in window: NSWindow?,
        _ identifier: NSToolbarItem.Identifier,
        hiddenBy visibility: ToolbarVisibility?
    ) -> NSToolbarItem? {
        /// Anchoring a popover on a toolbar item is macOS 14, and an item whose view AppKit
        /// generates reports `view` as nil, so there is nothing to anchor on below it. Answering
        /// nil sends the caller to the floating panel, which is the same route an overflowed
        /// toolbar already takes.
        guard #available(macOS 14.0, *) else { return nil }
        guard let toolbar = window?.toolbar, toolbar.isVisible else { return nil }
        guard visibility?.hides(identifier) != true else { return nil }
        return toolbar.items.first { $0.itemIdentifier == identifier }
    }
}
