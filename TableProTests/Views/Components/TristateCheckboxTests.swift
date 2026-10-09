//
//  TristateCheckboxTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct TristateCheckboxTests {
    private func mount(_ view: some View) throws -> (NSWindow, NSButton) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(firstButton(in: window.contentView))
        return (window, button)
    }

    private func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }

    @Test("A click whose action changes nothing leaves the box unchecked", arguments: [1, 2, 3])
    func noOpClickKeepsUnchecked(clicks: Int) throws {
        var actions = 0
        let (window, button) = try mount(TristateCheckbox(state: .unchecked) { actions += 1 })
        defer { window.close() }

        for _ in 0..<clicks {
            button.performClick(nil)
        }

        #expect(actions == clicks)
        #expect(button.state == .off)
    }

    @Test("A click whose action changes nothing leaves the box checked")
    func noOpClickKeepsChecked() throws {
        let (window, button) = try mount(TristateCheckbox(state: .checked) {})
        defer { window.close() }

        button.performClick(nil)

        #expect(button.state == .on)
    }

    @Test("A click whose action changes nothing leaves the box mixed")
    func noOpClickKeepsMixed() throws {
        let (window, button) = try mount(TristateCheckbox(state: .mixed) {})
        defer { window.close() }

        button.performClick(nil)

        #expect(button.state == .mixed)
    }

    @Test("The title is the checkbox's own label")
    func titleIsTheButtonsLabel() throws {
        let (window, button) = try mount(TristateCheckbox(state: .checked, title: "Select All") {})
        defer { window.close() }

        #expect(button.title == "Select All")
        #expect(button.accessibilityTitle() == "Select All")
    }

    @Test("A disabled checkbox cannot be clicked")
    func disabledModifierDisablesTheButton() throws {
        let (window, button) = try mount(TristateCheckbox(state: .unchecked) {}.disabled(true))
        defer { window.close() }

        #expect(button.isEnabled == false)
    }
}
