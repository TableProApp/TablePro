//
//  TristateCheckbox.swift
//  TablePro
//

import AppKit
import SwiftUI

struct TristateCheckbox: NSViewRepresentable {
    enum State {
        case unchecked, checked, mixed

        init(allEnabled: Bool?) {
            switch allEnabled {
            case .some(true): self = .checked
            case .some(false): self = .unchecked
            case .none: self = .mixed
            }
        }
    }

    let state: State
    var title: String?
    var accessibilityLabel: String?
    var accessibilityValue: String?
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title ?? "",
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:))
        )
        button.allowsMixedState = true
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.state = state.controlState
        if let title, button.title != title {
            button.title = title
        }
        button.isEnabled = context.environment.isEnabled
        if let accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
        }
        if let accessibilityValue {
            button.setAccessibilityValue(accessibilityValue)
        }
        context.coordinator.state = state
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, action: action)
    }

    class Coordinator: NSObject {
        var state: State
        var action: () -> Void

        init(state: State, action: @escaping () -> Void) {
            self.state = state
            self.action = action
        }

        /// AppKit has already moved the box to its next state (on, off, mixed). Putting the model's
        /// state back means a click that changes nothing cannot leave a dash or a check nobody holds.
        @objc func clicked(_ sender: NSButton) {
            sender.state = state.controlState
            action()
        }
    }
}

private extension TristateCheckbox.State {
    var controlState: NSControl.StateValue {
        switch self {
        case .unchecked: .off
        case .checked: .on
        case .mixed: .mixed
        }
    }
}
