//
//  SidebarRowForegroundTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// Emphasis is not a role any more. AppKit publishes the row's background prominence into the
/// hosted view, so `.primary` and `.secondary` answer it themselves and only the active-object
/// tint has a decision to make.
@Suite("Sidebar row foreground")
struct SidebarRowForegroundTests {
    @Test("The active tint outranks the system dimming")
    func activeBeatsSystem() {
        #expect(SidebarRowForeground.role(isActive: true, isSystem: true) == .active)
    }

    @Test("A system object that is not active dims")
    func systemAlone() {
        #expect(SidebarRowForeground.role(isActive: false, isSystem: true) == .system)
    }

    @Test("A plain row uses the primary label")
    func plainRow() {
        #expect(SidebarRowForeground.role(isActive: false, isSystem: false) == .normal)
    }
}
