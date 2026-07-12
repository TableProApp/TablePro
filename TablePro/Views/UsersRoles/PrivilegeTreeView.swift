import AppKit
import SwiftUI
import TableProPluginKit

struct PrivilegeTreeView: NSViewRepresentable {
    let roots: [PrivilegeNode]
    let version: Int
    let privileges: [PluginPrivilegeDescriptor]
    let catalog: PluginPrivilegeCatalog
    let isGranted: (String, PluginPrivilegeScope) -> Bool
    let hasDescendantGrant: (String, PluginPrivilegeScope) -> Bool
    let onToggle: (String, PluginPrivilegeScope, Bool) -> Void
    let onExpand: (PrivilegeNode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .inset
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.headerView = NSTableHeaderView()
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing

        context.coordinator.outlineView = outlineView
        context.coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let scopeColumnIdentifier = NSUserInterfaceItemIdentifier("scope")

        var parent: PrivilegeTreeView
        weak var outlineView: NSOutlineView?

        private var installedPrivileges: [String] = []

        init(_ parent: PrivilegeTreeView) {
            self.parent = parent
        }

        func configureColumns(on outlineView: NSOutlineView) {
            let desired = parent.privileges.map(\.name)
            guard desired != installedPrivileges else { return }
            installedPrivileges = desired

            for column in outlineView.tableColumns {
                outlineView.removeTableColumn(column)
            }

            let scopeColumn = NSTableColumn(identifier: Self.scopeColumnIdentifier)
            scopeColumn.title = String(localized: "Object")
            scopeColumn.width = 240
            scopeColumn.minWidth = 160
            outlineView.addTableColumn(scopeColumn)

            for privilege in parent.privileges {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(privilege.name))
                column.title = privilege.label
                column.width = 110
                column.minWidth = 60
                outlineView.addTableColumn(column)
            }
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
            guard let node = item as? PrivilegeNode else { return parent.roots }
            return node.children ?? []
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? PrivilegeNode,
                  !node.hasLoadedChildren else { return }
            parent.onExpand(node)
        }
    }
}
