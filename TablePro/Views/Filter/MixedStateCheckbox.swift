//
//  MixedStateCheckbox.swift
//  TablePro
//
//  NSViewRepresentable checkbox that supports mixed (indeterminate) state.
//

import AppKit
import SwiftUI

struct MixedStateCheckbox: NSViewRepresentable {
    let title: String
    let state: NSControl.StateValue
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.didToggle(_:)))
        button.allowsMixedState = true
        button.font = NSFont.systemFont(ofSize: 11)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.state = state
        button.font = NSFont.systemFont(ofSize: 11)
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func didToggle(_ sender: NSButton) {
            action()
        }
    }
}
