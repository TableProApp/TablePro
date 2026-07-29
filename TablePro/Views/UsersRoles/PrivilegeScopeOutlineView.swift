import AppKit
import SwiftUI
import TableProPluginKit

struct PrivilegeScopeOutlineView: NSViewRepresentable {
    @Bindable var viewModel: UsersRolesViewModel

    let structureVersion: Int
    let grantVersion: Int
    let principal: PluginPrincipalRef?

    func makeCoordinator() -> PrivilegeScopeOutlineCoordinator {
        PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.allowsColumnResizing = true
        outlineView.autosaveName = "com.TablePro.usersRoles.scopeOutline"
        outlineView.autosaveTableColumns = true
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityIdentifier("usersroles-scope-tree")

        context.coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        context.coordinator.outlineView = outlineView

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewModel = viewModel

        guard let outlineView = nsView.documentView as? NSOutlineView else { return }

        if coordinator.structureVersion != structureVersion {
            coordinator.structureVersion = structureVersion
            coordinator.grantVersion = grantVersion
            coordinator.principal = principal
            outlineView.reloadData()
            coordinator.restoreExpansion()
        } else if coordinator.grantVersion != grantVersion || coordinator.principal != principal {
            // The summary column renders the selected principal's grants, so a change of principal
            // must refresh it even when the tree structure and the grant closure are unchanged.
            coordinator.grantVersion = grantVersion
            coordinator.principal = principal
            coordinator.refreshVisibleSummaries()
        }
    }
}
