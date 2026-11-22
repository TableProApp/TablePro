//
//  EditorRowFocus.swift
//  TablePro
//

import AppKit
import SwiftUI

extension View {
    // A row whose SwiftUI field carries `.focused(isFocused)`.
    func editorRowFocus(
        _ rows: EditorRow...,
        store: ConnectionEditorStore,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        modifier(EditorFocusRequestModifier(rows: rows, store: store) { isFocused.wrappedValue = true })
    }

    // Any other row: a picker, a toggle, a code editor, an AppKit control or a composite row. It scrolls into view and
    // its first control that takes focus does, where Keyboard Navigation lets a pop-up or a toggle take it.
    func editorRowFocus(_ row: EditorRow, store: ConnectionEditorStore) -> some View {
        modifier(EditorRowAnchorFocusModifier(row: row, store: store))
    }

    // A row that picks which of its fields takes the focus.
    func onEditorFocusRequest(_ row: EditorRow, store: ConnectionEditorStore, perform: @escaping @MainActor () -> Void) -> some View {
        modifier(EditorFocusRequestModifier(rows: [row], store: store, perform: perform))
    }
}

private struct EditorFocusRequestModifier: ViewModifier {
    let rows: [EditorRow]
    @ObservedObject var store: ConnectionEditorStore
    let perform: @MainActor () -> Void

    @State private var handledToken: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { apply(store.focusRequest) }
            .onChange(of: store.focusRequest) { apply($0) }
    }

    // Deferred a turn: a facet built for this request is not in the window yet when it lands.
    private func apply(_ request: FocusRequest?) {
        guard let request, rows.contains(request.row), request.token != handledToken else { return }
        handledToken = request.token
        DispatchQueue.main.async {
            perform()
            store.didApplyFocus(request)
        }
    }
}

private struct EditorRowAnchorFocusModifier: ViewModifier {
    let row: EditorRow
    let store: ConnectionEditorStore

    @State private var target = EditorRowFocusTarget()

    func body(content: Content) -> some View {
        content
            .background(EditorRowFocusAnchor(target: target))
            .onEditorFocusRequest(row, store: store) { target.focus() }
    }
}

// SwiftUI cannot focus a field inside an AppKit control or a composite row, so the row's own frame finds it.
@MainActor
final class EditorRowFocusTarget {
    weak var anchor: NSView?
    private var pendingFocus = false

    func focus() {
        guard let anchor, let window = anchor.window else {
            pendingFocus = true
            return
        }
        pendingFocus = false
        anchor.scrollToVisible(anchor.bounds)
        if let control = Self.firstFocusableView(inside: anchor, of: window) {
            window.makeFirstResponder(control)
        }
    }

    func anchorDidMoveToWindow() {
        guard pendingFocus else { return }
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    // Text input first, in reading order; a control only when the row has no text input.
    static func firstFocusableView(inside anchor: NSView, of window: NSWindow) -> NSView? {
        guard let root = window.contentView else { return nil }
        let area = anchor.convert(anchor.bounds, to: nil).insetBy(dx: -2, dy: -2)
        var candidates: [(view: NSView, rect: NSRect, isText: Bool)] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard !view.isHiddenOrHasHiddenAncestor, view !== anchor, view.acceptsFirstResponder else { continue }
            if let textView = view as? NSTextView, textView.isFieldEditor { continue }
            let frameView = (view as? NSTextView)?.enclosingScrollView ?? view
            let rect = frameView.convert(frameView.bounds, to: nil)
            guard rect.width > 0, rect.height > 0, area.contains(NSPoint(x: rect.midX, y: rect.midY)) else { continue }
            let isText = view is NSTextView || (view as? NSTextField)?.isEditable == true
            guard isText || view.canBecomeKeyView else { continue }
            candidates.append((view, rect, isText))
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.isText != rhs.isText { return lhs.isText }
            if abs(lhs.rect.maxY - rhs.rect.maxY) > 1 { return lhs.rect.maxY > rhs.rect.maxY }
            return lhs.rect.minX < rhs.rect.minX
        }
        return ordered.first?.view
    }
}

private struct EditorRowFocusAnchor: NSViewRepresentable {
    let target: EditorRowFocusTarget

    func makeNSView(context: Context) -> EditorRowFocusAnchorView {
        let view = EditorRowFocusAnchorView()
        view.target = target
        target.anchor = view
        return view
    }

    func updateNSView(_ view: EditorRowFocusAnchorView, context: Context) {
        view.target = target
        target.anchor = view
    }
}

final class EditorRowFocusAnchorView: NSView {
    weak var target: EditorRowFocusTarget?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            target?.anchorDidMoveToWindow()
        }
    }

    // A background, never a target for clicks or VoiceOver.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
}
