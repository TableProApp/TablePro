//
//  CommandFRouteTests.swift
//  TableProTests
//
//  Tests for CommandFRoute, which decides where Cmd+F resolves so exactly one
//  menu item owns the shortcut per context.
//

@testable import TablePro
import Testing

@Suite("CommandFRouteTests")
struct CommandFRouteTests {
    @Test("Inspector window takes priority over tab type")
    func inspectorWins() {
        #expect(CommandFRoute.resolve(isInspector: true, isTableTab: true) == .inspectorFilter)
        #expect(CommandFRoute.resolve(isInspector: true, isTableTab: false) == .inspectorFilter)
    }

    @Test("Table tab routes to the View-menu filter toggle")
    func tableTabFilters() {
        #expect(CommandFRoute.resolve(isInspector: false, isTableTab: true) == .tableFilter)
    }

    @Test("Everything else routes to the editor Find panel")
    func otherwiseFinds() {
        #expect(CommandFRoute.resolve(isInspector: false, isTableTab: false) == .editorFind)
    }
}
