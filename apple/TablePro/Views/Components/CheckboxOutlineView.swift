//
//  CheckboxOutlineView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Adds the one key an `NSOutlineView` of checkboxes needs and does not get for free. Arrow keys,
/// Left and Right to collapse and expand, Home and End and type-select are all AppKit's own once
/// the rows are selectable.
internal final class CheckboxOutlineView: NSOutlineView {
    internal var toggleSelectedRows: (() -> Void)?

    override internal func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ", !selectedRowIndexes.isEmpty else {
            super.keyDown(with: event)
            return
        }
        toggleSelectedRows?()
    }
}

/// The cell keeps one hosting view for the life of the row and only swaps its root, because
/// rebuilding the host on every reload loses the SwiftUI state the checkboxes animate from.
///
/// A recycled row still reconciles against the previous row's `@State` unless the content carries
/// an `.id()` of its own, so every caller gives the root view the row's identity.
internal final class HostingTableCellView: NSTableCellView {
    private let hosting: NSHostingView<AnyView>

    internal init(identifier: NSUserInterfaceItemIdentifier) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func configure(with content: AnyView) {
        hosting.rootView = content
    }
}

internal final class CheckboxTableCellView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var modelState: NSControl.StateValue = .off
    private var action: (() -> Void)?

    internal init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = self
        checkbox.action = #selector(clicked(_:))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func configure(
        state: NSControl.StateValue,
        isEnabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        modelState = state
        self.action = action
        checkbox.allowsMixedState = state == .mixed
        checkbox.state = state
        checkbox.isEnabled = isEnabled
        checkbox.setAccessibilityLabel(accessibilityLabel)
    }

    // AppKit already moved the box to its next state; the action decides the real one.
    @objc private func clicked(_ sender: NSButton) {
        sender.state = modelState
        action?()
    }
}
