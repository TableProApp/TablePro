//
//  ConnectionEditorSplitViewController.swift
//  TablePro
//

import AppKit

// The editor is chrome: no theme slot and no ThemeBackdropState, only the system sidebar material and
// each Form's own background.
@MainActor
final class ConnectionEditorSplitViewController: NSSplitViewController {
    let sidebar = ConnectionEditorSidebarViewController()
    let detail: ConnectionEditorDetailViewController
    private let store: ConnectionEditorStore

    init(store: ConnectionEditorStore, onCloseMissingRecord: @escaping () -> Void) {
        self.store = store
        self.detail = ConnectionEditorDetailViewController(store: store, onCloseMissingRecord: onCloseMissingRecord)
        super.init(nibName: nil, bundle: nil)
        sidebar.onSelectFacet = { [weak self] facet in
            guard let self else { return }
            store.selectedFacet = facet
            detail.show(.facet(facet))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorSplitViewController does not support NSCoder init")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = ConnectionEditorWindowFrame.sidebarWidth
        sidebarItem.maximumThickness = ConnectionEditorWindowFrame.sidebarWidth
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detail)
        // The divider comes out of the fixed width, so the detail minimum leaves room for it.
        detailItem.minimumThickness = ConnectionEditorWindowFrame.detailWidth - splitView.dividerThickness
        detailItem.holdingPriority = .splitPaneHolding
        addSplitViewItem(detailItem)

        sync()
    }

    func sync() {
        guard isViewLoaded else { return }
        let isRecordMissing = store.isRecordMissing
        sidebar.show(ConnectionEditorSidebarRow.rows(for: store), selecting: isRecordMissing ? nil : store.selectedFacet)
        detail.show(isRecordMissing ? .recordMissing : .facet(store.selectedFacet))
    }
}
