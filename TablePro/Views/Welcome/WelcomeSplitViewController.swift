//
//  WelcomeSplitViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class WelcomeSplitViewController: NSSplitViewController {
    internal static let sidebarWidth: CGFloat = 260
    internal static let listMinimumWidth: CGFloat = 460

    private let viewModel: WelcomeViewModel
    private let toolbarPresentation: WelcomeToolbarPresentation

    internal init(viewModel: WelcomeViewModel, toolbarPresentation: WelcomeToolbarPresentation) {
        self.viewModel = viewModel
        self.toolbarPresentation = toolbarPresentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeSplitViewController does not support NSCoder init")
    }

    override internal func viewDidLoad() {
        super.viewDidLoad()

        let sidebar = NSHostingController(rootView: WelcomeSidebarPane(viewModel: viewModel))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.holdingPriority = .splitPaneHolding
        addSplitViewItem(sidebarItem)

        let libraryPane = WelcomeLibraryPane(
            viewModel: viewModel,
            toolbarPresentation: toolbarPresentation
        )
            .environment(\.appServices, .live)
        let list = NSHostingController(rootView: libraryPane)
        list.sizingOptions = []
        /// `sceneBridgingOptions` is macOS 14. It lets the hosted SwiftUI tree contribute toolbar
        /// items to the window; on 13 the pane simply contributes none, and the window keeps the
        /// toolbar the controller builds itself.
        if #available(macOS 14.0, *) {
            list.sceneBridgingOptions = [.toolbars]
        }
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = Self.listMinimumWidth
        addSplitViewItem(listItem)
    }
}

internal struct WelcomeSidebarPane: View {
    let viewModel: WelcomeViewModel

    var body: some View {
        WelcomeActionsPanel(
            onActivateLicense: { viewModel.activeSheet = .activation },
            onNewConnection: { WindowOpener.shared.openConnectionForm() },
            onOpenFile: { NSApp.sendAction(#selector(AppDelegate.openFile(_:)), to: nil, from: nil) },
            onImportFromURL: { viewModel.urlImportPresented = true },
            onImportFromApp: { viewModel.importConnectionsFromApp() },
            onImportFromAWS: { viewModel.importConnectionsFromAWS() },
            onImportConnectionsFile: { viewModel.importConnectionsFromFile() },
            onOpenProjectFolder: { viewModel.openProjectFolder() }
        )
    }
}
