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
        let captured = ChromePaneLayout(
            isSidebarCollapsed: true,
            isTrailingPaneCollapsed: true
        )

        #expect(captured.isSidebarCollapsed)
        #expect(captured.isTrailingPaneCollapsed)
    }

    @Test("An open inspector is captured the same way")
    func capturesAnOpenInspector() {
        let captured = ChromePaneLayout(
            isSidebarCollapsed: false,
            isTrailingPaneCollapsed: false
        )

        #expect(captured.isSidebarCollapsed == false)
        #expect(captured.isTrailingPaneCollapsed == false)
    }

    /// Two windows with the same panes compare equal, which is what lets the reveal tell a captured
    /// layout from no capture at all.
    @Test("Two identical layouts compare equal")
    func layoutsAreComparable() {
        let first = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: true
        )
        let second = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: true
        )
        let different = ChromePaneLayout(
            isSidebarCollapsed: true, isTrailingPaneCollapsed: true
        )

        #expect(first == second)
        #expect(first != different)
    }

}
