//
//  WelcomeWindowController.swift
//  TablePro
//

import AppKit
import TableProConnectionLibrary

@MainActor
internal final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    internal static let contentSize = NSSize(width: 900, height: 600)

    internal static var frameAutosaveName: NSWindow.FrameAutosaveName? {
        SplitViewAutosaveName.current(WindowIdentifier.welcome)
    }

    private static var shared: WelcomeWindowController?

    private let viewModel: WelcomeViewModel
    private let toolbarController: WelcomeToolbarController

    internal static func present() {
        let controller = shared ?? WelcomeWindowController(viewModel: WelcomeViewModel())
        shared = controller
        controller.viewModel.refreshImportableApp()
        controller.viewModel.loadConnections()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
        controller.viewModel.focusList()
        controller.decideSetupGuideAfterFirstFrame()
    }

    // The guide opens in front of Welcome once Welcome has drawn and taken any routed request.
    private func decideSetupGuideAfterFirstFrame() {
        guard SetupGuidePresenter.shared.state == .undecided, let window else { return }
        window.afterNextFrame { [weak self] in
            SetupGuidePresenter.shared.welcomeDidAppear(hasRoutedWork: self?.viewModel.hasRoutedPresentation ?? false)
        }
    }

    internal static func makeWelcomeWindow() -> NSWindow {
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
        return window
    }

    private init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        let window = Self.makeWelcomeWindow()
        let toolbarController = WelcomeToolbarController(viewModel: viewModel)
        toolbarController.install(in: window)
        self.toolbarController = toolbarController
        window.contentViewController = WelcomeSplitViewController(viewModel: viewModel)
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        super.init(window: window)
        window.delegate = self

        if !window.setFrame(usingAutosaveName: Self.frameAutosaveName) {
            window.center()
        }
        window.setContentSize(Self.contentSize)
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
        WelcomeRouter.shared.welcomeDidClose()
    }

    // MARK: - Commands

    @objc
    internal func performFind(_ sender: Any?) {
        toolbarController.beginSearch()
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
