import AppKit
import SwiftUI
import TableProPluginKit

extension PrivilegeTreeView.Coordinator {
    enum CheckboxState {
        case notApplicable
        case notGranted
        case granted
        case grantedBelow

        var controlState: NSControl.StateValue {
            switch self {
            case .granted: .on
            case .grantedBelow: .mixed
            case .notGranted, .notApplicable: .off
            }
        }

        var toolTip: String? {
            switch self {
            case .notApplicable:
                String(localized: "Not grantable at this level")
            case .grantedBelow:
                String(localized: "Granted on one or more objects inside this one")
            case .granted, .notGranted:
                nil
            }
        }
    }

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

    @objc
    func toggle(_ sender: NSButton) {
        guard let outlineView else { return }
        let row = outlineView.row(for: sender)
        guard row >= 0, let node = outlineView.item(atRow: row) as? PrivilegeNode else { return }

        let privilege = sender.identifier?.rawValue ?? ""
        guard !privilege.isEmpty else { return }

        let shouldGrant = !parent.isGranted(privilege, node.scope)
        apply(shouldGrant ? .granted : state(of: privilege, at: node), to: sender)
        parent.onToggle(privilege, node.scope, shouldGrant)
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
        apply(state(of: privilege, at: node), to: button)
        return button
    }

    private func state(of privilege: String, at node: PrivilegeNode) -> CheckboxState {
        let isApplicable = parent.catalog
            .privileges(for: node.scope)
            .contains { $0.name == privilege }
        guard isApplicable else { return .notApplicable }

        if parent.isGranted(privilege, node.scope) {
            return .granted
        }
        if parent.hasDescendantGrant(privilege, node.scope) {
            return .grantedBelow
        }
        return .notGranted
    }

    private func apply(_ state: CheckboxState, to button: NSButton) {
        button.allowsMixedState = state != .notApplicable
        button.isEnabled = state != .notApplicable
        button.state = state.controlState
        button.toolTip = state.toolTip
    }
}
