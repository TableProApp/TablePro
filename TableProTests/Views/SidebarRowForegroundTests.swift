//
//  SidebarRowForegroundTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Sidebar row foreground")
struct SidebarRowForegroundTests {
    @Test("Emphasis outranks the active tint")
    func emphasisBeatsActive() {
        #expect(SidebarRowForeground.role(isEmphasized: true, isActive: true, isSystem: false) == .emphasized)
    }

    @Test("Emphasis outranks the system dimming")
    func emphasisBeatsSystem() {
        #expect(SidebarRowForeground.role(isEmphasized: true, isActive: false, isSystem: true) == .emphasized)
    }

    @Test("The active tint outranks the system dimming")
    func activeBeatsSystem() {
        #expect(SidebarRowForeground.role(isEmphasized: false, isActive: true, isSystem: true) == .active)
    }

    @Test("A system object without emphasis or activity dims")
    func systemAlone() {
        #expect(SidebarRowForeground.role(isEmphasized: false, isActive: false, isSystem: true) == .system)
    }

    @Test("A plain row uses the primary label")
    func plainRow() {
        #expect(SidebarRowForeground.role(isEmphasized: false, isActive: false, isSystem: false) == .normal)
    }
}
