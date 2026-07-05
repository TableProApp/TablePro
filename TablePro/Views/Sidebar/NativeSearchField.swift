//
//  NativeSearchField.swift
//  TablePro
//
//  Native NSSearchField wrapped for SwiftUI.
//

import AppKit
import SwiftUI

private final class IntrinsicHeightSearchField: NSSearchField {
    var focusOnAppear = false
    private var windowKeyObserver: NSObjectProtocol?

    override var intrinsicContentSize: NSSize {
        let cellHeight = cell?.cellSize.height ?? super.intrinsicContentSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: cellHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowKeyObserver()
        guard focusOnAppear, acceptsFirstResponder, let window else { return }
        if window.isKeyWindow {
            window.makeFirstResponder(self)
            return
        }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeWindowKeyObserver()
                self.window?.makeFirstResponder(self)
            }
        }
    }

    private func removeWindowKeyObserver() {
        guard let token = windowKeyObserver else { return }
        NotificationCenter.default.removeObserver(token)
        windowKeyObserver = nil
    }

    deinit {
        if let token = windowKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var controlSize: NSControl.ControlSize = .regular
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSubmit: (() -> Void)?
    var focusOnAppear: Bool = false
    var focusTrigger: Int = 0
    var maxWidth: CGFloat?
    var accessibilityIdentifier: String = "sidebar-filter"

    func makeNSView(context: Context) -> NSSearchField {
        let field = IntrinsicHeightSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = controlSize
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.cell?.usesSingleLineMode = true
        if let maxWidth {
            field.preferredMaxLayoutWidth = maxWidth
            field.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        }
        context.coordinator.lastFocusTrigger = focusTrigger
        field.focusOnAppear = focusOnAppear
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.controlSize != controlSize {
            field.controlSize = controlSize
            field.invalidateIntrinsicContentSize()
        }
        field.placeholderString = placeholder
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onSubmit = onSubmit

        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?
        var onSubmit: (() -> Void)?
        var lastFocusTrigger: Int = 0

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
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard let field = control as? NSSearchField, !field.stringValue.isEmpty else {
                    return false
                }
                field.stringValue = ""
                text.wrappedValue = ""
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), let onMoveUp {
                onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)), let onMoveDown {
                onMoveDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit {
                onSubmit()
                return true
            }
            return false
        }
    }
}
