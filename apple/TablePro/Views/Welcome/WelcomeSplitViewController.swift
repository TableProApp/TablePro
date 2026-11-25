//
//  WelcomeSplitViewController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

@MainActor
internal final class WelcomeSplitViewController: NSSplitViewController {
    internal static let sidebarWidth: CGFloat = 260
    internal static let listMinimumWidth: CGFloat = 460

    private let viewModel: WelcomeViewModel
    private var listItem: NSSplitViewItem?
    private var listPane: WelcomeListPaneController?
    private(set) var tagFilterBar: WelcomeTagFilterBar?
    private var tagFilterCancellable: AnyCancellable?

    internal init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
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
        let sidebarItem = NSSplitViewItem.navigationSidebar(sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.holdingPriority = .splitPaneHolding
        addSplitViewItem(sidebarItem)

        let list = NSHostingController(
            rootView: WelcomeLibraryPane(viewModel: viewModel)
                .environment(\.appServices, .live)
        )
        list.sizingOptions = []
        let listItem: NSSplitViewItem
        if #available(macOS 26.0, *) {
            listItem = NSSplitViewItem(viewController: list)
        } else {
            let pane = WelcomeListPaneController(content: list)
            listPane = pane
            listItem = NSSplitViewItem(viewController: pane)
        }
        listItem.minimumThickness = Self.listMinimumWidth
        addSplitViewItem(listItem)
        self.listItem = listItem

        tagFilterCancellable = viewModel.$tagFilter.sink { [weak self] filter in
            self?.showTagFilter(filter)
        }
    }

    // Built when the first tag turns on, so the first frame never pays for it.
    private func showTagFilter(_ filter: WelcomeTagFilter) {
        guard filter.isActive else {
            hideTagFilterBar()
            return
        }
        if let tagFilterBar {
            tagFilterBar.apply(filter)
            return
        }
        let bar = WelcomeTagFilterBar(viewModel: viewModel)
        bar.apply(filter)
        tagFilterBar = bar
        if #available(macOS 26.0, *) {
            let accessory = NSSplitViewItemAccessoryViewController()
            accessory.view = bar
            listItem?.addTopAlignedAccessoryViewController(accessory)
        } else {
            listPane?.showBar(bar)
        }
    }

    private func hideTagFilterBar() {
        guard tagFilterBar != nil else { return }
        tagFilterBar = nil
        if #available(macOS 26.0, *) {
            guard let listItem, !listItem.topAlignedAccessoryViewControllers.isEmpty else { return }
            listItem.removeTopAlignedAccessoryViewController(at: 0)
        } else {
            listPane?.showBar(nil)
        }
    }
}

internal struct WelcomeSidebarPane: View {
    let viewModel: WelcomeViewModel

    var body: some View {
        WelcomeActionsPanel(
            onSignIn: { SignInWindowController.present() },
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
