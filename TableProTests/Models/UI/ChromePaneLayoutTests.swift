//
//  ChromePaneLayoutTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Chrome pane layout")
struct ChromePaneLayoutTests {
    @Test("A hidden sidebar the user chose is still hidden when the chrome comes back")
    func restoresAHiddenSidebar() {
        let captured = ChromePaneLayout(isSidebarCollapsed: true, isInspectorCollapsed: true)

        #expect(ChromePaneLayout.toRestore(captured: captured) == captured)
    }

    @Test("An open inspector survives a connection dropping and coming back")
    func restoresAnOpenInspector() {
        let captured = ChromePaneLayout(isSidebarCollapsed: false, isInspectorCollapsed: false)

        #expect(ChromePaneLayout.toRestore(captured: captured) == captured)
    }

    @Test("A window that has never hidden its chrome opens on the sidebar with no inspector")
    func firstRevealUsesTheFreshWindowLayout() {
        let restored = ChromePaneLayout.toRestore(captured: nil)

        #expect(restored.isSidebarCollapsed == false)
        #expect(restored.isInspectorCollapsed)
    }
}
