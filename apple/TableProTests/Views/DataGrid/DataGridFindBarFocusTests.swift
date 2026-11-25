//
//  DataGridFindBarFocusTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

// The find bar is rebuilt every time its tab comes back on screen, and its field took the keyboard on each rebuild,
// so clicking a table in the sidebar and switching back to a tab with Find open greyed the sidebar row.
@MainActor
struct DataGridFindBarFocusTests {
    // The headless host never gives a window the keyboard, and the field only claims focus in a key window.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private static let frame = NSRect(x: 0, y: 0, width: 700, height: 300)

    private func makeWindow() -> KeyWindow {
        let window = KeyWindow(contentRect: Self.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: Self.frame)
        return window
    }

    private func mountBar(_ model: DataGridModel, in window: NSWindow) async throws -> NSHostingView<DataGridFindBar> {
        let host = NSHostingView(rootView: DataGridFindBar(model: model))
        host.frame = NSRect(x: 0, y: 200, width: 700, height: 60)
        window.contentView?.addSubview(host)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return host.firstDescendant(of: NSSearchField.self) != nil
        }
        return host
    }

    private func holdsKeyboard(_ field: NSTextField?, in window: NSWindow) -> Bool {
        guard let field, let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    @Test("Find takes the keyboard into the bar it opens")
    func findFocusesTheField() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.contentView = nil }
        let model = DataGridModel()

        model.showFind()
        let host = try await mountBar(model, in: window)

        let field = host.firstDescendant(of: NSSearchField.self)
        try await waitUntil { holdsKeyboard(field, in: window) }
    }

    @Test("A find bar rebuilt by a tab switch leaves the keyboard where it is")
    func rebuiltBarLeavesFocusAlone() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.contentView = nil }
        let elsewhere = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 22))
        window.contentView?.addSubview(elsewhere)
        let model = DataGridModel()
        model.showFind()
        let first = try await mountBar(model, in: window)
        try await waitUntil { !model.find.requestsFieldFocus }

        #expect(window.makeFirstResponder(elsewhere))
        first.removeFromSuperview()
        let second = try await mountBar(model, in: window)

        #expect(second.firstDescendant(of: NSSearchField.self) != nil)
        #expect(holdsKeyboard(elsewhere, in: window))
    }

    @Test("Closing Find withdraws a request the bar never took")
    func hideFindWithdrawsTheRequest() {
        let model = DataGridModel()

        model.showFind()
        #expect(model.find.requestsFieldFocus)
        model.hideFind()

        #expect(!model.find.requestsFieldFocus)
    }
}
