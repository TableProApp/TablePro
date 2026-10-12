//
//  MySQLSessionLossTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MySQLSessionLossTests {
    private final class Handle {}

    @Test("A live connection is used as it is")
    func liveConnectionIsUsed() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: "an open transaction")
        let verdict = loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: false, killWasApproved: true, holding: "an open transaction")
        #expect(verdict == .useConnection)
        #expect(!loss.isLost)
    }

    @Test("A killed session that held nothing is taken again without a word")
    func cleanSessionIsReacquired() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: nil)
        #expect(loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: nil) == .reacquire)
        #expect(!loss.isLost)
    }

    @Test("A killed session that held something is reported once, then stays lost")
    func heldSessionIsReportedOnce() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: "an open transaction")
        let first = loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: nil)
        #expect(first == .report(reason: "an open transaction"))
        #expect(loss.isLost)
        #expect(loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: nil) == .lost)
    }

    @Test("A kill nobody noted still reports what the session holds now")
    func unnotedKillReportsCurrentState() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        let verdict = loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: "a user variable")
        #expect(verdict == .report(reason: "a user variable"))
    }

    @Test("A statement observed after a clean kill does not turn it into a loss")
    func cleanNoteOutranksLaterFootprint() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: nil)
        let verdict = loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: "a user variable")
        #expect(verdict == .reacquire)
        #expect(!loss.isLost)
    }

    @Test("A note left by a kill that never went out does not hide a later cleanup kill's loss")
    func abandonedNoteIsIgnoredForCleanupKill() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: nil)
        let verdict = loss.verdict(
            for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: false, holding: "an open transaction"
        )
        #expect(verdict == .report(reason: "an open transaction"))
        #expect(loss.isLost)
    }

    @Test("A later stop over a clean session clears an earlier note")
    func cleanStopClearsEarlierNote() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: "an open transaction")
        loss.noteKill(on: ObjectIdentifier(handle), holding: nil)
        #expect(loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: nil) == .reacquire)
    }

    @Test("A note taken on another connection says nothing about this one")
    func noteOnOtherConnectionIsIgnored() {
        let earlier = Handle()
        let current = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(earlier), holding: "an open transaction")
        #expect(loss.verdict(for: ObjectIdentifier(current), sessionEndedByKill: true, killWasApproved: true, holding: nil) == .reacquire)
    }

    @Test("Reset forgets the loss")
    func resetForgetsTheLoss() {
        let handle = Handle()
        var loss = MySQLSessionLoss()
        loss.noteKill(on: ObjectIdentifier(handle), holding: "a temporary table")
        _ = loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: true, killWasApproved: true, holding: nil)
        loss.reset()
        #expect(!loss.isLost)
        #expect(loss.verdict(for: ObjectIdentifier(handle), sessionEndedByKill: false, killWasApproved: true, holding: nil) == .useConnection)
    }
}
