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
            isTrailingPaneCollapsed: true,
            trailingSurface: .inspector
        )

        #expect(captured.isSidebarCollapsed)
        #expect(captured.isTrailingPaneCollapsed)
    }

    @Test("An open inspector is captured the same way")
    func capturesAnOpenInspector() {
        let captured = ChromePaneLayout(
            isSidebarCollapsed: false,
            isTrailingPaneCollapsed: false,
            trailingSurface: .inspector
        )

        #expect(captured.isSidebarCollapsed == false)
        #expect(captured.isTrailingPaneCollapsed == false)
    }

    /// Two windows with the same panes compare equal, which is what lets the reveal tell a captured
    /// layout from no capture at all.
    @Test("Two identical layouts compare equal")
    func layoutsAreComparable() {
        let first = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: true, trailingSurface: .inspector
        )
        let second = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: true, trailingSurface: .inspector
        )
        let different = ChromePaneLayout(
            isSidebarCollapsed: true, isTrailingPaneCollapsed: true, trailingSurface: .inspector
        )

        #expect(first == second)
        #expect(first != different)
    }

    /// One split item hosts both surfaces, so recording only that the pane was open would reveal
    /// the inspector over a user who had the assistant up.
    @Test("Two layouts that differ only by surface are not equal")
    func surfaceIsPartOfTheLayout() {
        let inspector = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: false, trailingSurface: .inspector
        )
        let assistant = ChromePaneLayout(
            isSidebarCollapsed: false, isTrailingPaneCollapsed: false, trailingSurface: .assistant
        )

        #expect(inspector != assistant)
        #expect(assistant.trailingSurface == .assistant)
    }
}
