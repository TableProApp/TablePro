//
//  ChromePaneLayoutTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Chrome pane layout")
struct ChromePaneLayoutTests {
    @Test("A hidden sidebar the user chose is captured so the reveal can put it back")
    func capturesAHiddenSidebar() {
        let captured = ChromePaneLayout(isSidebarCollapsed: true, isInspectorCollapsed: true)

        #expect(captured.isSidebarCollapsed)
        #expect(captured.isInspectorCollapsed)
    }

    @Test("An open inspector is captured the same way")
    func capturesAnOpenInspector() {
        let captured = ChromePaneLayout(isSidebarCollapsed: false, isInspectorCollapsed: false)

        #expect(captured.isSidebarCollapsed == false)
        #expect(captured.isInspectorCollapsed == false)
    }

    /// Two windows with the same panes compare equal, which is what lets the reveal tell a captured
    /// layout from no capture at all.
    @Test("Two identical layouts compare equal")
    func layoutsAreComparable() {
        let first = ChromePaneLayout(isSidebarCollapsed: false, isInspectorCollapsed: true)
        let second = ChromePaneLayout(isSidebarCollapsed: false, isInspectorCollapsed: true)
        let different = ChromePaneLayout(isSidebarCollapsed: true, isInspectorCollapsed: true)

        #expect(first == second)
        #expect(first != different)
    }
}
