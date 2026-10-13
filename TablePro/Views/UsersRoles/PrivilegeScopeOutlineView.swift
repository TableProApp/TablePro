import AppKit
import SwiftUI
import TableProPluginKit

struct PrivilegeScopeOutlineView: NSViewRepresentable {
    @ObservedObject var viewModel: UsersRolesViewModel

    let structureVersion: Int
    let grantVersion: Int
    let principal: PluginPrincipalRef?

    func makeCoordinator() -> PrivilegeScopeOutlineCoordinator {
        PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    static func makeScrollView(coordinator: PrivilegeScopeOutlineCoordinator) -> NSScrollView {
        let outlineView = PrivilegeScopeOutline()
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.allowsColumnResizing = true
        outlineView.autosaveName = SplitViewAutosaveName.current("com.TablePro.usersRoles.scopeOutline")
        outlineView.autosaveTableColumns = true
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityIdentifier("usersroles-scope-tree")

        coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        coordinator.outlineView = outlineView

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Attached last: the chrome records the scroll view's background to give it back.
        outlineView.themeChrome = ThemeTableChrome(tableView: outlineView, family: .records)
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

internal final class PrivilegeScopeOutline: NSOutlineView {
    internal var themeChrome: ThemeTableChrome?

    internal var isRebuildingRows: Bool {
        themeChrome?.isRebuildingRows ?? false
    }
}

internal extension PrivilegeScopeOutlineCoordinator {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (outlineView as? PrivilegeScopeOutline)?.themeChrome?.makeRowView(in: outlineView)
    }

    func cell(_ identifier: NSUserInterfaceItemIdentifier, in outlineView: NSOutlineView, showing content: some View) -> NSView {
        ThemeTableChrome.HostingCell.make(identifier, in: outlineView, showing: content)
    }
}
