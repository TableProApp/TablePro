//
//  QuickSwitcherSearchField.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct QuickSwitcherSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> QuickSwitcherTextField {
        let field = QuickSwitcherTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = placeholder
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: QuickSwitcherTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: QuickSwitcherSearchField

        init(_ parent: QuickSwitcherSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !control.stringValue.isEmpty else { return false }
                control.stringValue = ""
                parent.text = ""
                return true
            default:
                return false
            }
        }
    }
}

internal final class QuickSwitcherTextField: NSTextField {
    private var becomeKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if window.isKeyWindow {
            window.makeFirstResponder(self)
            return
        }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                if let observer = self.becomeKeyObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.becomeKeyObserver = nil
                }
            }
        }
    }

    deinit {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
    }
}
