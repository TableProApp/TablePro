//
//  AssistantSafeModeFloorTests.swift
//  TableProTests
//
//  Assistant mode promises a write waits for a human. On a `.silent` connection, which is the
//  default in both the initializer and the decoder, that promise used to be false.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Assistant Safe Mode floor")
struct AssistantSafeModeFloorTests {
    @Test("Silent is raised to Confirm Writes, so a proposed write stops for a human")
    func silentIsRaised() {
        let raised = AssistantSafeModeFloor.effectiveLevel(stored: .silent, assistantModeActive: true)

        #expect(raised == .alert)
        #expect(raised.requiresConfirmation)
    }

    @Test("The floor is a minimum, never a maximum")
    func strictLevelsAreNotLowered() {
        for level in [SafeModeLevel.alert, .alertFull, .safeMode, .safeModeFull, .readOnly] {
            #expect(
                AssistantSafeModeFloor.effectiveLevel(stored: level, assistantModeActive: true) == level,
                "\(level) was changed by the floor"
            )
        }
    }

    /// Someone who deliberately set Read-Only must not find the assistant able to write, and
    /// Read-Only reports `requiresConfirmation == false` because there is nothing to confirm.
    /// Lowering it to Alert would have turned a block into a prompt.
    @Test("Read-Only stays read-only under the floor")
    func readOnlyStaysReadOnly() {
        let raised = AssistantSafeModeFloor.effectiveLevel(stored: .readOnly, assistantModeActive: true)

        #expect(raised == .readOnly)
        #expect(raised.blocksAllWrites)
    }

    @Test("With the mode off, every level is returned untouched")
    func inactiveFloorChangesNothing() {
        for level in SafeModeLevel.allCases {
            #expect(
                AssistantSafeModeFloor.effectiveLevel(stored: level, assistantModeActive: false) == level,
                "\(level) was changed while the mode was off"
            )
        }
    }

    @Test("Leaving the mode gives the user's own level back with nothing stored")
    func leavingTheModeRestoresTheLevel() {
        let stored = SafeModeLevel.silent

        #expect(AssistantSafeModeFloor.effectiveLevel(stored: stored, assistantModeActive: true) == .alert)
        #expect(AssistantSafeModeFloor.effectiveLevel(stored: stored, assistantModeActive: false) == .silent)
    }

    @Test("raised(toFloor:) never lowers a level, for any pair")
    func raisedIsMonotonic() {
        for level in SafeModeLevel.allCases {
            for floor in SafeModeLevel.allCases {
                let result = level.raised(toFloor: floor)
                #expect(
                    result == level || result == floor,
                    "\(level) raised to \(floor) produced \(result), which is neither"
                )
                #expect(
                    level.raised(toFloor: level) == level,
                    "\(level) raised to itself changed"
                )
            }
        }
    }

    @Test("A floor of Silent asks nothing of any level")
    func silentFloorIsANoOp() {
        for level in SafeModeLevel.allCases {
            #expect(level.raised(toFloor: .silent) == level, "\(level) was changed by a Silent floor")
        }
    }
}
