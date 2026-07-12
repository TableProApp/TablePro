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
        private static let scopeColumnIdentifier = NSUserInterfaceItemIdentifier("scope")

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

        // MARK: - Delegate

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let tableColumn, let node = item as? PrivilegeNode else { return nil }

            if tableColumn.identifier == Self.scopeColumnIdentifier {
                return label(for: node, outlineView: outlineView, column: tableColumn)
            }
            return checkbox(
                privilege: tableColumn.identifier.rawValue,
                node: node,
                outlineView: outlineView,
                column: tableColumn
            )
        }

        private func label(
            for node: PrivilegeNode,
            outlineView: NSOutlineView,
            column: NSTableColumn
        ) -> NSView {
            let field: NSTextField
            if let reused = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = column.identifier
                field.lineBreakMode = .byTruncatingMiddle
            }
            field.stringValue = node.title
            return field
        }

        private func checkbox(
            privilege: String,
            node: PrivilegeNode,
            outlineView: NSOutlineView,
            column: NSTableColumn
        ) -> NSView {
            let button: NSButton
            if let reused = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSButton {
                button = reused
            } else {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                button.identifier = column.identifier
                button.alignment = .center
            }

            button.target = self
            button.action = #selector(toggle(_:))
            button.allowsMixedState = true

            let applicable = parent.catalog
                .privileges(for: node.scope)
                .contains { $0.name == privilege }
            button.isEnabled = applicable

            if !applicable {
                button.allowsMixedState = false
                button.state = .off
                button.toolTip = String(localized: "Not grantable at this level")
                return button
            }

            if parent.isGranted(privilege, node.scope) {
                button.state = .on
                button.toolTip = nil
            } else if parent.hasDescendantGrant(privilege, node.scope) {
                button.state = .mixed
                button.toolTip = String(localized: "Granted on one or more objects inside this one")
            } else {
                button.state = .off
                button.toolTip = nil
            }
            return button
        }

        @objc
        private func toggle(_ sender: NSButton) {
            guard let outlineView else { return }
            let row = outlineView.row(for: sender)
            guard row >= 0, let node = outlineView.item(atRow: row) as? PrivilegeNode else { return }

            let privilege = sender.identifier?.rawValue ?? ""
            guard !privilege.isEmpty else { return }

            let wasGranted = parent.isGranted(privilege, node.scope)
            let shouldGrant = !wasGranted

            if shouldGrant {
                sender.state = .on
            } else {
                sender.state = parent.hasDescendantGrant(privilege, node.scope) ? .mixed : .off
            }
            parent.onToggle(privilege, node.scope, shouldGrant)
        }
    }
}
