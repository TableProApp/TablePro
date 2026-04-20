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

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = controlSize
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier("sidebar-filter")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            text.wrappedValue = ""
            sender.window?.makeFirstResponder(nil)
        }
    }
}
