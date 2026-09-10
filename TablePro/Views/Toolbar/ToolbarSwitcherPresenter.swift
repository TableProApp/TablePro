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
    internal func present(
        from window: NSWindow?,
        anchoredTo identifier: NSToolbarItem.Identifier,
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
        return anchor(identifier, in: toolbar.items, visible: toolbar.visibleItems ?? [])
    }

    /// The anchor for an identifier that may name a subitem of a group rather than an item the
    /// toolbar carries directly.
    ///
    /// The connection and the container are two subitems of one centred native group, and anchoring
    /// both choosers to the group put each of them on the seam between the two capsules rather than
    /// under the one it belongs to. Measured on a 1200pt window: the group's midpoint is 600.0, the
    /// Connection capsule's is 543.2 and the Container capsule's is 671.8, and a popover anchored to
    /// the group lands at 600.0 for both. A subitem does resolve as an anchor and lands on its own
    /// capsule to within a point, even though `NSToolbar.items` lists groups only and a native
    /// group's subitems carry no `view`.
    ///
    /// It resolves only while the group is on screen. Once AppKit clips the group into the overflow
    /// menu its subitems have no view and `NSPopover.show(relativeTo:)` raises
    /// `NSInvalidArgumentException` ("view has no window"), which Swift cannot catch; measured, that
    /// is exactly the width at which `visibleItems` stops naming the group. The group keeps working
    /// there, because AppKit presents a clipped item from another affordance in the window itself,
    /// so an overflowed group is the fallback rather than the floating panel.
    internal static func anchor(
        _ identifier: NSToolbarItem.Identifier,
        in items: [NSToolbarItem],
        visible: [NSToolbarItem]
    ) -> NSToolbarItem? {
        if let item = items.first(where: { $0.itemIdentifier == identifier }) { return item }
        let groups = items.compactMap { $0 as? NSToolbarItemGroup }
        guard let group = groups.first(where: { group in
            group.subitems.contains { $0.itemIdentifier == identifier }
        }) else { return nil }
        guard visible.contains(where: { $0.itemIdentifier == group.itemIdentifier }) else { return group }
        return group.subitems.first { $0.itemIdentifier == identifier }
    }
}
