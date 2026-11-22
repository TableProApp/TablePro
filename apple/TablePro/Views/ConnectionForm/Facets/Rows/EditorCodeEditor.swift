//
//  EditorCodeEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

enum EditorCodeLanguage {
    case sql
    case shell
    case plain
    case json
}

// A multi-line editor that is a Section of its own: the header names it. It grows with its lines from minHeight,
// Tab leaves it as in any form field, and Escape stays inside it instead of cancelling the window.
struct EditorCodeEditor: View {
    @Binding private var text: String
    private let language: EditorCodeLanguage
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let minHeight: CGFloat

    @State private var isEdited = false

    private static let maxHeight: CGFloat = 320

    init(
        text: Binding<String>,
        language: EditorCodeLanguage,
        row: EditorRow,
        store: ConnectionEditorStore,
        minHeight: CGFloat = 96
    ) {
        _text = text
        self.language = language
        self.row = row
        self.store = store
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextValueEditor(
                text: $text,
                font: font,
                borderType: .bezelBorder,
                movesFocusOnTab: true,
                style: language == .plain ? .plain : .code
            )
            .frame(height: height)
            .background(EditorCodeEditorAnchor(focusToken: focusToken))
            .accessibilityIdentifier(row.accessibilityIdentifier)

            if let issue = EditorIssueVisibility.issue(for: row, in: store, isEdited: isEdited) {
                NoticeLabel(issue.message, severity: issue.severity == .error ? .error : .warning)
            }
        }
        .onChange(of: text) { _ in isEdited = true }
    }

    private var font: NSFont {
        let size = NSFont.systemFontSize
        return language == .plain
            ? .systemFont(ofSize: size)
            : .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var focusToken: UUID? {
        guard let request = store.focusRequest, request.row == row else { return nil }
        return request.token
    }

    // Hard line breaks only: a wrapped long line scrolls inside the editor rather than growing it.
    private var height: CGFloat {
        let lines = CGFloat(text.reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        })
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let chrome: CGFloat = 16
        let content = lines * lineHeight + chrome
        return min(max(content, minHeight), max(minHeight, Self.maxHeight))
    }
}

// The editor's text view is TextValueEditor's, shared with the grid and the inspectors, so the editor-only key
// handling lives here. A window's Cancel button answers Escape as a key equivalent before the text view sees the
// key, which is why a local monitor, not the text view's delegate, keeps it.
private struct EditorCodeEditorAnchor: NSViewRepresentable {
    let focusToken: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchor = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.focus(token: focusToken)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        private var monitor: Any?
        private var handledToken: UUID?

        private static let escapeKeyCode: UInt16 = 53

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
                nonisolated(unsafe) let event = nsEvent
                let swallowed = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    return self.swallows(event)
                }
                return swallowed ? nil : nsEvent
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func swallows(_ event: NSEvent) -> Bool {
            guard event.keyCode == Self.escapeKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  let window = anchor?.window, event.window === window,
                  let textView = window.firstResponder as? NSTextView
            else { return false }
            return owns(textView)
        }

        func focus(token: UUID?) {
            guard let token, token != handledToken else { return }
            handledToken = token
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.anchor?.window, let textView = self.ownedTextView(in: window) else { return }
                window.makeFirstResponder(textView)
            }
        }

        // The anchor is the editor's background, so it covers the same rect as the editor's scroll view.
        private func owns(_ textView: NSTextView) -> Bool {
            guard !textView.isFieldEditor, let anchor, let scrollView = textView.enclosingScrollView else { return false }
            let anchorRect = anchor.convert(anchor.bounds, to: nil).insetBy(dx: -2, dy: -2)
            let editorRect = scrollView.convert(scrollView.bounds, to: nil)
            return anchorRect.contains(CGPoint(x: editorRect.midX, y: editorRect.midY))
        }

        private func ownedTextView(in window: NSWindow) -> NSTextView? {
            guard let root = window.contentView else { return nil }
            var stack: [NSView] = [root]
            while let view = stack.popLast() {
                if let textView = view as? NSTextView, owns(textView) { return textView }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
