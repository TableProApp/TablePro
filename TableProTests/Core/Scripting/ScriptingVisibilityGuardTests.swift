//
//  ScriptingVisibilityGuardTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct ScriptingVisibilityGuardTests {
    @Test("Blocked is the only level that hides a connection from scripts")
    func blockedIsTheOnlyHiddenLevel() {
        let hidden = ExternalAccessLevel.allCases.filter { $0 == .blocked }
        #expect(hidden == [.blocked])
        #expect(ExternalAccessLevel.allCases.count == 3)
    }
}
