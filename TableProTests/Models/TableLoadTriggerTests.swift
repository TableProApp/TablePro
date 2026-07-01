//
//  TableLoadTriggerTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

@Suite("TableLoadTrigger")
struct TableLoadTriggerTests {
    @Test("Restore trigger suppresses the failure modal")
    func restoreSuppressesModal() {
        #expect(TableLoadTrigger.restore.suppressesFailureModal == true)
    }

    @Test("User-initiated trigger does not suppress the failure modal")
    func userInitiatedShowsModal() {
        #expect(TableLoadTrigger.userInitiated.suppressesFailureModal == false)
    }
}
