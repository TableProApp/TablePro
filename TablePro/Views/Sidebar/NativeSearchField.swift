//
//  NativeSearchField.swift
//  TablePro
//
//  Native NSSearchField wrapped for SwiftUI.
//

import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var controlSize: NSControl.ControlSize = .regular
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var focusOnAppear: Bool = false

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = controlSize
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier("sidebar-filter")
        if focusOnAppear {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            text.wrappedValue = ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)), let onMoveUp {
                onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)), let onMoveDown {
                onMoveDown()
                return true
            }
            return false
        }
    }
}
