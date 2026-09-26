//
//  WelcomeWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

@MainActor
internal final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    internal static let contentSize = NSSize(width: 900, height: 600)

    internal static var frameAutosaveName: NSWindow.FrameAutosaveName? {
        SplitViewAutosaveName.current(WindowIdentifier.welcome)
    }

    private static var shared: WelcomeWindowController?

    private let viewModel: WelcomeViewModel
    private let toolbarPresentation = WelcomeToolbarPresentation()
    private var toolbarDisplayModeObservation: NSKeyValueObservation?

    internal static func present() {
        let controller = shared ?? WelcomeWindowController(viewModel: WelcomeViewModel())
        shared = controller
        controller.viewModel.refreshImportableApp()
        controller.viewModel.loadConnections()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
        controller.viewModel.focusList()
    }

    private init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to TablePro")
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.welcome)
        window.keepsKeyViewLoopCurrent()
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])

        let toolbar = NSToolbar(identifier: "com.TablePro.welcome.toolbar")
        Self.configureToolbar(toolbar)
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        super.init(window: window)
        window.delegate = self
        window.contentViewController = WelcomeSplitViewController(
            viewModel: viewModel,
            toolbarPresentation: toolbarPresentation
        )
        Self.configureLiveToolbar(in: window)
        observeDisplayMode(of: window.toolbar)

        if !window.setFrame(usingAutosaveName: Self.frameAutosaveName) {
            window.center()
        }
        window.setContentSize(Self.contentSize)
    }

    internal static func configureToolbar(_ toolbar: NSToolbar) {
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
    }

    internal static func configureLiveToolbar(in window: NSWindow) {
        window.toolbarStyle = .unified
        guard let toolbar = window.toolbar else { return }
        configureToolbar(toolbar)
    }

    private func observeDisplayMode(of toolbar: NSToolbar?) {
        guard let toolbar else { return }
        toolbarDisplayModeObservation = Self.keepIconOnlyDisplayMode(of: toolbar)
    }

    internal static func keepIconOnlyDisplayMode(of toolbar: NSToolbar) -> NSKeyValueObservation {
        toolbar.observe(\.displayMode, options: [.new]) { [weak toolbar] _, _ in
            MainActor.assumeIsolated {
                guard let toolbar, toolbar.displayMode != .iconOnly else { return }
                toolbar.displayMode = .iconOnly
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeWindowController does not support NSCoder init")
    }

    // MARK: - NSWindowDelegate

    internal func windowDidMove(_ notification: Notification) {
        window?.saveFrame(usingAutosaveName: Self.frameAutosaveName)
    }

    internal func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingAutosaveName: Self.frameAutosaveName)
    }

    // MARK: - Commands

    @objc
    internal func performFind(_ sender: Any?) {
        let searchItem = window?.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first
        searchItem?.beginSearchInteraction()
    }

    @objc
    internal func newConnectionGroup(_ sender: Any?) {
        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [])
    }

    @objc
    internal func renameConnectionListSelection(_ sender: Any?) {
        viewModel.renameSelection()
    }

    @objc
    internal func sortConnectionList(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(LibrarySortMode.init(rawValue:)) else { return }
        viewModel.setSortMode(mode)
    }
}

extension WelcomeWindowController: NSMenuItemValidation {
    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isKey = window?.isKeyWindow == true
        switch menuItem.action {
        case #selector(performFind(_:)):
            return isKey && viewModel.isSearchAvailable
        case #selector(newConnectionGroup(_:)):
            return isKey
        case #selector(renameConnectionListSelection(_:)):
            return isKey && viewModel.renamableRow(in: viewModel.selection) != nil
        case #selector(sortConnectionList(_:)):
            let mode = (menuItem.representedObject as? String).flatMap(LibrarySortMode.init(rawValue:))
            menuItem.state = mode == viewModel.sortMode ? .on : .off
            return isKey && mode != nil
        default:
            return true
        }
    }
}
