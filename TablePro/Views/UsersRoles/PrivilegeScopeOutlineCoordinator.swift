import AppKit
import SwiftUI
import TableProPluginKit

@MainActor
final class PrivilegeScopeOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let scopeColumn = NSUserInterfaceItemIdentifier("scope")
    static let summaryColumn = NSUserInterfaceItemIdentifier("summary")

    var viewModel: UsersRolesViewModel
    weak var outlineView: NSOutlineView?

    var structureVersion = -1
    var grantVersion = -1
    var principal: PluginPrincipalRef?

    private var isRestoringExpansion = false
    private var pendingExpansions: Set<String> = []

    init(viewModel: UsersRolesViewModel) {
        self.viewModel = viewModel
    }

    func configureColumns(on outlineView: NSOutlineView) {
        guard outlineView.tableColumns.isEmpty else { return }

        // The pane's minimum thickness is 240pt, so the two columns must fit inside that or the
        // summary is clipped away entirely.
        let scope = NSTableColumn(identifier: Self.scopeColumn)
        scope.title = String(localized: "Object")
        scope.width = 150
        scope.minWidth = 110
        outlineView.addTableColumn(scope)

        let summary = NSTableColumn(identifier: Self.summaryColumn)
        summary.title = String(localized: "Privileges")
        summary.width = 130
        summary.minWidth = 90
        outlineView.addTableColumn(summary)

        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.sizeLastColumnToFit()
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PrivilegeNode)?.isExpandable ?? false
    }

    private func children(of item: Any?) -> [PrivilegeNode] {
        guard let node = item as? PrivilegeNode else { return viewModel.privilegeTree.roots }
        return node.children ?? []
    }

    // MARK: - Expansion

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !isRestoringExpansion,
              let node = notification.userInfo?["NSObject"] as? PrivilegeNode,
              !node.hasLoadedChildren,
              !node.isLoading else { return }

        pendingExpansions.insert(node.persistentKey)

        Task { @MainActor in
            await viewModel.expand(node)
            guard let outlineView else { return }

            // The user can collapse the node again while its children are loading. Honour that
            // instead of re-expanding underneath them.
            guard pendingExpansions.remove(node.persistentKey) != nil else {
                outlineView.reloadItem(node, reloadChildren: true)
                return
            }
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion,
              let node = notification.userInfo?["NSObject"] as? PrivilegeNode else { return }
        viewModel.expansionStore.insert(node.persistentKey)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion,
              let node = notification.userInfo?["NSObject"] as? PrivilegeNode else { return }
        pendingExpansions.remove(node.persistentKey)
        viewModel.expansionStore.remove(node.persistentKey)
    }

    func restoreExpansion() {
        guard viewModel.privilegeTree.mode == .hierarchy else { return }

        let saved = Set(viewModel.expansionStore.load())
        guard !saved.isEmpty else { return }

        Task { @MainActor in
            isRestoringExpansion = true
            defer { isRestoringExpansion = false }

            var frontier = viewModel.privilegeTree.roots
            while !frontier.isEmpty {
                var next: [PrivilegeNode] = []
                for node in frontier where saved.contains(node.persistentKey) {
                    if !node.hasLoadedChildren {
                        await viewModel.expand(node)
                    }
                    outlineView?.reloadItem(node, reloadChildren: true)
                    outlineView?.expandItem(node)
                    next.append(contentsOf: node.children ?? [])
                }
                frontier = next
            }
        }
    }

    // MARK: - Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView else { return }

        let scopes = outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? PrivilegeNode)?.scope
        }
        viewModel.selectedScopes = Set(scopes)
    }

    // MARK: - Cells

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let tableColumn, let node = item as? PrivilegeNode else { return nil }

        if tableColumn.identifier == Self.scopeColumn {
            return hostingCell(
                identifier: Self.scopeColumn,
                outlineView: outlineView,
                content: AnyView(
                    PrivilegeScopeRowView(
                        title: node.title,
                        symbolName: node.symbolName,
                        isLoading: node.isLoading,
                        loadError: node.loadError,
                        isRestricted: node.childrenAvailability == .restrictedToCurrentDatabase
                    )
                )
            )
        }

        return hostingCell(
            identifier: Self.summaryColumn,
            outlineView: outlineView,
            content: AnyView(ScopeSummaryView(summary: summary(for: node)))
        )
    }

    private func summary(for node: PrivilegeNode) -> ScopeSummary {
        guard let principal = viewModel.selection else { return .none }
        return viewModel.changeManager.summary(
            at: node.scope,
            for: principal,
            isBrowsingRestricted: node.childrenAvailability == .restrictedToCurrentDatabase
        )
    }

    private func hostingCell(
        identifier: NSUserInterfaceItemIdentifier,
        outlineView: NSOutlineView,
        content: AnyView
    ) -> NSView {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView> {
            reused.rootView = content
            return reused
        }
        let hosting = NSHostingView(rootView: content)
        hosting.identifier = identifier
        return hosting
    }

    func refreshVisibleSummaries() {
        guard let outlineView else { return }
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0 else { return }

        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: rows.location ..< rows.location + rows.length),
            columnIndexes: IndexSet(integersIn: 0 ..< outlineView.numberOfColumns)
        )
    }
}
