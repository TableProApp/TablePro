//
//  DataFileSplitViewController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DataFileSplitViewController: NSSplitViewController {
    static let inspectorMinThickness: CGFloat = 270
    static let contentMinThickness: CGFloat = 360

    weak var dataFileDocument: DataFileDocument?
    let controller: DataFileController
    let gridDelegate: DataFileGridDelegate
    private let contentItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var cancellables: Set<AnyCancellable> = []
    var statisticsPopover: NSPopover?
    var sheetController: NSViewController?
    let exportPresenter = ExportSheetPresenter()

    init(document: DataFileDocument) {
        dataFileDocument = document
        controller = document.controller
        gridDelegate = DataFileGridDelegate(controller: document.controller)

        let content = NSHostingController(rootView: DataFileContentView(
            controller: document.controller,
            gridDelegate: gridDelegate
        ))
        content.sizingOptions = []
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.contentMinThickness
        contentItem.holdingPriority = .defaultLow

        let inspector = NSHostingController(rootView: DataFileRowDetailsView(controller: document.controller))
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = Self.inspectorMinThickness
        inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        inspectorItem.holdingPriority = .splitPaneHolding
        inspectorItem.isCollapsed = true

        super.init(nibName: nil, bundle: nil)
        gridDelegate.owner = self
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        KeyWindowCommandSubscription
            .sink(AppCommands.shared.exportQueryResults, whileKey: { [weak self] in self?.view.window }) { [weak self] _ in
                self?.presentExport()
            }
            .store(in: &cancellables)

        controller.$isInspectorVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.inspectorItem.animator().isCollapsed = !visible
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = SplitViewAutosaveName.current("com.TablePro.DataFileSplit")
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let visible = !inspectorItem.isCollapsed
        if controller.isInspectorVisible != visible {
            controller.isInspectorVisible = visible
        }
    }

    var dataFileWindowController: DataFileWindowController? {
        view.window?.windowController as? DataFileWindowController
    }

    func focusGrid() {
        guard let tableView = controller.gridCoordinator?.tableView else { return }
        view.window?.makeFirstResponder(tableView)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let validation = validation(for: item.action) else {
            return super.validateUserInterfaceItem(item)
        }
        if let menuItem = item as? NSMenuItem, let title = validation.title {
            menuItem.title = title
        }
        if let menuItem = item as? NSMenuItem, let state = validation.state {
            menuItem.state = state
        }
        return validation.isEnabled
    }
}
