//
//  CompareEndpointToolbarController.swift
//  TablePro
//
//  The Source and Target toolbar buttons, and the chooser each one reveals.
//
//  An endpoint is a database, not a connection. Picking only a connection is
//  what made two databases on one server impossible to compare and left the
//  schema unset, so the chooser is connection then database then schema.
//

import AppKit
import SwiftUI

@MainActor
internal final class CompareEndpointToolbarController: NSObject {
    private let session: CompareSyncSession
    private let onChange: () -> Void
    private let windowProvider: () -> NSWindow?

    private var identifiers: [DatabaseEndpointSide: NSToolbarItem.Identifier] = [:]
    private var popover: NSPopover?
    private var closeObserver: (any NSObjectProtocol)?

    internal init(
        session: CompareSyncSession,
        windowProvider: @escaping () -> NSWindow?,
        onChange: @escaping () -> Void
    ) {
        self.session = session
        self.windowProvider = windowProvider
        self.onChange = onChange
        super.init()
    }

    internal func item(for side: DatabaseEndpointSide, identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        identifiers[side] = identifier
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = side.title
        item.paletteLabel = side.title
        item.image = NSImage(systemSymbolName: side.symbol, accessibilityDescription: side.title)
        item.isBordered = true
        item.target = self
        item.action = side == .source ? #selector(chooseSource(_:)) : #selector(chooseTarget(_:))
        apply(side, to: item)
        return item
    }

    /// Resolved from the live toolbar rather than from an item this controller kept. Customize
    /// Toolbar asks the delegate for more copies with `willBeInsertedIntoToolbar` false, so a
    /// retained reference ends up naming a palette item that was thrown away, and the button the
    /// user is looking at keeps its old title forever.
    internal func refreshTitles() {
        guard let toolbar = windowProvider()?.toolbar else { return }
        for (side, identifier) in identifiers {
            for item in toolbar.items where item.itemIdentifier == identifier {
                apply(side, to: item)
            }
        }
    }

    private func apply(_ side: DatabaseEndpointSide, to item: NSToolbarItem) {
        let endpoint = endpoint(for: side)
        item.title = endpoint?.qualifiedDescription ?? side.placeholderTitle
        item.toolTip = endpoint?.fullDescription ?? side.caption
    }

    private func endpoint(for side: DatabaseEndpointSide) -> DatabaseEndpoint? {
        side == .source ? session.source : session.target
    }

    // MARK: - Presentation

    @objc private func chooseSource(_ sender: Any?) {
        present(.source)
    }

    @objc private func chooseTarget(_ sender: Any?) {
        present(.target)
    }

    /// Pressing the button again closes the chooser, which is what a pull-down control does and
    /// what the popover's own `.transient` dismissal would otherwise fight.
    private func present(_ side: DatabaseEndpointSide) {
        guard popover?.isShown != true else {
            dismiss()
            return
        }
        guard let identifier = identifiers[side],
              let anchor = ToolbarSwitcherPresenter.anchor(in: windowProvider(), identifier) else { return }

        let shown = PopoverPresenter.show(
            relativeTo: anchor,
            contentSize: DatabaseEndpointPicker.contentSize,
            behavior: .transient
        ) { dismiss in
            DatabaseEndpointPicker(
                side: side,
                current: self.endpoint(for: side),
                onPick: { [weak self] endpoint in self?.pick(endpoint, for: side) },
                dismiss: dismiss
            )
        }
        popover = shown
        /// AppKit closes a transient popover by itself and reports it nowhere else. Without this
        /// the controller holds a closed popover, and through it the SwiftUI tree and every
        /// database list the chooser loaded, until the next presentation.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: shown,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetPopover() }
        }
    }

    internal func dismiss() {
        popover?.performClose(nil)
        forgetPopover()
    }

    private func forgetPopover() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        popover = nil
    }

    /// Re-picking the endpoint that is already chosen must not reach `onChange`, which resets the
    /// comparison: the report, both snapshots, every data plan and the user's per-object choices.
    private func pick(_ endpoint: DatabaseEndpoint, for side: DatabaseEndpointSide) {
        guard self.endpoint(for: side)?.id != endpoint.id else { return }
        switch side {
        case .source: session.source = endpoint
        case .target: session.target = endpoint
        }
        refreshTitles()
        onChange()
    }
}
