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
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        switch state {
        case .unchecked: button.state = .off
        case .checked: button.state = .on
        case .mixed: button.state = .mixed
        }
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func clicked() {
            action()
        }
    }
}
