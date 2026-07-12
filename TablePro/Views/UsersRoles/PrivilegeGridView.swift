import AppKit
import SwiftUI
import TableProPluginKit

struct PrivilegeGridView: NSViewRepresentable {
    let scopes: [PluginPrivilegeScope]
    let privileges: [PluginPrivilegeDescriptor]
    let databasePrivileges: Set<String>
    let serverPrivileges: Set<String>
    let isGranted: (String, PluginPrivilegeScope) -> Bool
    let onToggle: (String, PluginPrivilegeScope, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .default
        tableView.headerView = NSTableHeaderView()

        context.coordinator.configureColumns(on: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = nsView.documentView as? NSTableView else { return }
        context.coordinator.configureColumns(on: tableView)
        tableView.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let scopeColumnIdentifier = NSUserInterfaceItemIdentifier("scope")

        var parent: PrivilegeGridView
        weak var tableView: NSTableView?

        private var installedPrivileges: [String] = []

        init(_ parent: PrivilegeGridView) {
            self.parent = parent
        }

        func configureColumns(on tableView: NSTableView) {
            let desired = parent.privileges.map(\.name)
            guard desired != installedPrivileges else { return }
            installedPrivileges = desired

            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            let scopeColumn = NSTableColumn(identifier: Self.scopeColumnIdentifier)
            scopeColumn.title = String(localized: "Scope")
            scopeColumn.width = 200
            scopeColumn.minWidth = 120
            tableView.addTableColumn(scopeColumn)

            for privilege in parent.privileges {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(privilege.name))
                column.title = privilege.label
                column.width = 110
                column.minWidth = 60
                tableView.addTableColumn(column)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.scopes.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn, row < parent.scopes.count else { return nil }
            let scope = parent.scopes[row]

            if tableColumn.identifier == Self.scopeColumnIdentifier {
                return scopeLabel(for: scope, tableView: tableView, column: tableColumn)
            }
            return checkbox(
                privilege: tableColumn.identifier.rawValue,
                scope: scope,
                tableView: tableView,
                column: tableColumn
            )
        }

        private func scopeLabel(
            for scope: PluginPrivilegeScope,
            tableView: NSTableView,
            column: NSTableColumn
        ) -> NSView {
            let identifier = column.identifier
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingMiddle
            }
            field.stringValue = Self.title(for: scope)
            return field
        }

        private func checkbox(
            privilege: String,
            scope: PluginPrivilegeScope,
            tableView: NSTableView,
            column: NSTableColumn
        ) -> NSView {
            let identifier = column.identifier
            let button: NSButton
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
                button = reused
            } else {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                button.identifier = identifier
                button.alignment = .center
            }

            button.target = self
            button.action = #selector(toggle(_:))
            button.state = parent.isGranted(privilege, scope) ? .on : .off
            button.isEnabled = isApplicable(privilege: privilege, scope: scope)
            button.toolTip = button.isEnabled
                ? nil
                : String(localized: "Not available at this scope")
            return button
        }

        private func isApplicable(privilege: String, scope: PluginPrivilegeScope) -> Bool {
            switch scope {
            case .server:
                parent.serverPrivileges.contains(privilege)
            case .database:
                parent.databasePrivileges.contains(privilege)
            case .schema, .table:
                false
            }
        }

        @objc
        private func toggle(_ sender: NSButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            guard row >= 0, row < parent.scopes.count else { return }

            let privilege = sender.identifier?.rawValue ?? ""
            guard !privilege.isEmpty else { return }
            parent.onToggle(privilege, parent.scopes[row], sender.state == .on)
        }

        private static func title(for scope: PluginPrivilegeScope) -> String {
            switch scope {
            case .server:
                String(localized: "Server (all databases)")
            case let .database(name):
                name
            case let .schema(_, schema):
                schema
            case let .table(_, _, table):
                table
            }
        }
    }
}
