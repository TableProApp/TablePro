//
//  AlertWindowResolutionTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Alert window resolution")
@MainActor
struct AlertWindowResolutionTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    private func makePanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    @Test("A titled window is a content window")
    func titledWindowQualifies() {
        #expect(AlertHelper.isContentWindow(makeWindow()))
    }

    @Test("A floating panel is not a content window")
    func panelIsRejected() {
        #expect(AlertHelper.isContentWindow(makePanel()) == false)
    }

    @Test("An explicit window is honoured without a search")
    func explicitWindowWins() {
        let window = makeWindow()
        #expect(AlertHelper.resolveWindow(window) === window)
    }

    @Test("A titled panel is still rejected")
    func titledPanelIsRejected() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        #expect(AlertHelper.isContentWindow(panel) == false)
    }

    @Test("A borderless window is rejected")
    func borderlessWindowIsRejected() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        #expect(AlertHelper.isContentWindow(window) == false)
    }
}
