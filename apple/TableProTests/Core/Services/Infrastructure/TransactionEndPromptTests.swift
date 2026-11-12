//
//  TransactionEndPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TransactionEndPromptTests {
    private static func hold(
        _ connectionId: UUID = UUID(),
        lane: String? = nil,
        state: SessionTransactionTracker.State = .open
    ) -> SessionTransactionTracker.Hold {
        SessionTransactionTracker.Hold(key: .init(connectionId: connectionId, lane: lane), state: state, revision: 0)
    }

    private static func make(
        _ action: TransactionEndPrompt.Action,
        names: [String],
        holds: [SessionTransactionTracker.Hold],
        untracked: Bool = false,
        savedUnderManualCommit: Bool = false,
        hasUnsavedWork: Bool = false,
        readOnly: Set<UUID> = [],
        busy: Set<SessionTransactionTracker.Key> = []
    ) -> TransactionEndPrompt? {
        TransactionEndPrompt.make(
            action: action,
            names: names,
            holds: holds,
            untracked: untracked,
            savedUnderManualCommit: savedUnderManualCommit,
            hasUnsavedWork: hasUnsavedWork,
            effectiveLevel: { readOnly.contains($0) ? .readOnly : .silent },
            busy: { busy.contains($0.key) }
        )
    }

    @Test("Nothing holding a transaction asks nothing")
    func noTransactionNoPrompt() {
        #expect(Self.make(.disconnect(name: "Prod"), names: [], holds: []) == nil)
        #expect(Self.make(.quit, names: [], holds: []) == nil)
    }

    @Test("Disconnect asks to commit, names a database with its own session and says what is rolled back")
    func disconnectOffersCommit() throws {
        let prompt = try #require(Self.make(.disconnect(name: "Prod"), names: ["app"], holds: [Self.hold(lane: "app")]))

        #expect(prompt.offersCommit)
        #expect(prompt.title == "Do you want to commit the open transaction before disconnecting from “Prod”?")
        #expect(prompt.message == "The database “app” has an open transaction. Changes you don’t commit are rolled back.")
        #expect(!prompt.message.contains("\u{2014}"))
    }

    // A SQLite connection's database is its file path, which the title's connection name already stands for.
    @Test("A connection with one session for every database is not asked about by database name")
    func oneSessionConnectionNamesNoDatabase() throws {
        let prompt = try #require(Self.make(.disconnect(name: "Fixture"), names: ["/tmp/a.sqlite"], holds: [Self.hold()]))

        #expect(prompt.message == "Changes you don’t commit are rolled back.")
        let held = Self.hold()
        let busy = try #require(Self.make(
            .disconnect(name: "Fixture"), names: ["/tmp/a.sqlite"], holds: [held], busy: [held.key]
        ))
        #expect(!busy.offersCommit)
        #expect(busy.message.hasPrefix("This connection has an open transaction. Disconnecting rolls it back"))
        #expect(!busy.message.contains("a.sqlite"))
    }

    @Test("Several databases make the question plural and list every one")
    func severalDatabasesAreListed() throws {
        let id = UUID()
        let prompt = try #require(Self.make(
            .closeConnection(name: "Prod"),
            names: ["app", "logs"],
            holds: [Self.hold(id, lane: "app"), Self.hold(id, lane: "logs")]
        ))

        #expect(prompt.title == "Do you want to commit the open transactions before closing “Prod”?")
        #expect(prompt.message.contains("“app”"))
        #expect(prompt.message.contains("“logs”"))
        #expect(prompt.message.hasSuffix("Changes you don’t commit are rolled back."))
    }

    @Test("A database entry is named in the question")
    func entryCloseNamesTheDatabase() throws {
        let prompt = try #require(Self.make(.closeEntry(database: "logs"), names: ["logs"], holds: [Self.hold(lane: "logs")]))

        #expect(prompt.title == "Do you want to commit the open transaction before closing the database “logs”?")
        #expect(prompt.message == "Changes you don’t commit are rolled back.")
    }

    @Test("Disconnect keeps the unsaved-changes line, since Commit then disconnect still loses them")
    func disconnectKeepsUnsavedLine() throws {
        let prompt = try #require(Self.make(.disconnect(name: "Prod"), names: ["app"], holds: [Self.hold()], hasUnsavedWork: true))

        #expect(prompt.message.hasSuffix("Unsaved changes will be lost."))
    }

    @Test("A close asked about unsaved work on its own Save alert, so it carries no unsaved line")
    func closeCarriesNoUnsavedLine() throws {
        let prompt = try #require(Self.make(.closeConnection(name: "Prod"), names: ["app"], holds: [Self.hold()], hasUnsavedWork: true))

        #expect(!prompt.message.contains("Unsaved"))
    }

    @Test("Under Manual Commit the message says saved edits are not committed yet")
    func manualCommitNote() throws {
        let prompt = try #require(Self.make(
            .closeConnection(name: "Prod"), names: ["app"], holds: [Self.hold()], savedUnderManualCommit: true
        ))

        #expect(prompt.message.contains("Edits saved with Manual Commit on are not committed yet."))
        let disconnect = try #require(Self.make(
            .disconnect(name: "Prod"), names: ["app"], holds: [Self.hold()], savedUnderManualCommit: true
        ))
        #expect(!disconnect.message.contains("Manual Commit"))
    }

    @Test("Quit names each connection and keeps the unsaved-tabs line")
    func quitNamesConnections() throws {
        let prompt = try #require(Self.make(.quit, names: ["Prod"], holds: [Self.hold()], hasUnsavedWork: true))

        #expect(prompt.offersCommit)
        #expect(prompt.title == "Do you want to commit the open transaction before quitting?")
        #expect(prompt.message.hasPrefix("The connection “Prod” has an open transaction. Changes you don’t commit are rolled back."))
        #expect(prompt.message.hasSuffix("Some tabs have unsaved edits. Quitting will discard these changes."))
    }

    @Test("A connection holding two lanes is one name with plural transactions")
    func quitOneConnectionTwoLanes() throws {
        let id = UUID()
        let prompt = try #require(Self.make(.quit, names: ["Prod"], holds: [Self.hold(id, lane: "app"), Self.hold(id, lane: "logs")]))

        #expect(prompt.title == "Do you want to commit the open transactions before quitting?")
        #expect(prompt.message.hasPrefix("The connection “Prod” has open transactions."))
    }

    @Test("Relaunch speaks of relaunching, never of quitting")
    func relaunchWording() throws {
        let commit = try #require(Self.make(.relaunch, names: ["Prod"], holds: [Self.hold()], hasUnsavedWork: true))
        #expect(commit.title == "Do you want to commit the open transaction before relaunching?")
        #expect(commit.message.hasSuffix("Some tabs have unsaved edits. Relaunching will discard these changes."))
        #expect(!commit.message.contains("Quitting"))

        let rollBack = try #require(Self.make(
            .relaunch, names: ["Prod"], holds: [Self.hold(state: .aborted)], hasUnsavedWork: true
        ))
        #expect(rollBack.title == "Relaunch with an Open Transaction?")
        #expect(rollBack.confirmButton == "Relaunch Anyway")
        #expect(rollBack.message.hasPrefix("Uncommitted changes on “Prod” are rolled back when TablePro relaunches."))
        #expect(!rollBack.message.contains("quits"))
        #expect(!rollBack.message.contains("Quitting"))
    }

    @Test("Each action keeps its roll-back button when Commit is not offered")
    func rollBackButtons() throws {
        let aborted = [Self.hold(state: .aborted)]

        #expect(Self.make(.closeEntry(database: "app"), names: ["app"], holds: aborted)?.confirmButton == "Close")
        #expect(Self.make(.closeConnection(name: "Prod"), names: ["app"], holds: aborted)?.confirmButton == "Close")
        #expect(Self.make(.disconnect(name: "Prod"), names: ["app"], holds: aborted)?.confirmButton == "Disconnect")
        #expect(Self.make(.quit, names: ["Prod"], holds: aborted)?.confirmButton == "Quit Anyway")
        #expect(Self.make(.relaunch, names: ["Prod"], holds: aborted)?.confirmButton == "Relaunch Anyway")
    }

    @Test("A failed statement leaves only Roll Back and says why")
    func abortedOffersNoCommit() throws {
        let prompt = try #require(Self.make(.disconnect(name: "Prod"), names: ["app"], holds: [Self.hold(lane: "app", state: .aborted)]))

        #expect(prompt.commitBlock == .aborted)
        #expect(!prompt.offersCommit)
        #expect(prompt.title == "Disconnect from “Prod”?")
        #expect(prompt.message.hasPrefix(
            "The database “app” has an open transaction. Disconnecting rolls it back and discards its uncommitted changes."
        ))
        #expect(prompt.message.contains("A statement failed in the transaction, so it can only be rolled back."))
    }

    @Test("Read-Only Safe Mode leaves only Roll Back and says why")
    func readOnlyOffersNoCommit() throws {
        let id = UUID()
        let prompt = try #require(Self.make(.closeConnection(name: "Prod"), names: ["app"], holds: [Self.hold(id)], readOnly: [id]))

        #expect(prompt.commitBlock == .readOnly)
        #expect(prompt.title == "Close the connection “Prod”?")
        #expect(prompt.message.contains("Read-Only Safe Mode does not allow a commit."))
    }

    // The gate commits at the connection's level raised to the managed floor, so the prompt reads that level.
    @Test("A managed Read-Only floor leaves only Roll Back when the connection itself is below it")
    func managedFloorOffersNoCommit() throws {
        let floor = ManagedFloorPolicy(floor: .readOnly)
        let prompt = try #require(TransactionEndPrompt.make(
            action: .disconnect(name: "Prod"),
            names: ["app"],
            holds: [Self.hold()],
            effectiveLevel: { _ in ManagedPolicyResolver.effectiveSafeModeLevel(connectionLevel: .silent, policy: floor) },
            busy: { _ in false }
        ))

        #expect(prompt.commitBlock == .readOnly)
    }

    @Test("A statement still running in the transaction leaves only Roll Back and says why")
    func busyOffersNoCommit() throws {
        let hold = Self.hold(lane: "app")
        let prompt = try #require(Self.make(.closeEntry(database: "app"), names: ["app"], holds: [hold], busy: [hold.key]))

        #expect(prompt.commitBlock == .busy)
        #expect(prompt.title == "Close the database “app”?")
        #expect(prompt.message.contains("A statement is still running in the transaction, so it cannot be committed now."))
    }

    // The live read can find one the tracker never recorded, and a commit goes through a tracked hold only.
    @Test("A database with no tracked hold leaves only Roll Back")
    func untrackedOffersNoCommit() throws {
        let id = UUID()
        let partly = try #require(Self.make(
            .disconnect(name: "Prod"), names: ["app", "logs"], holds: [Self.hold(id, lane: "app")], untracked: true
        ))
        #expect(partly.commitBlock == .untracked)
        #expect(partly.message.hasPrefix("These databases have open transactions: "))
        #expect(partly.message.contains("“logs”"))

        let none = try #require(Self.make(.disconnect(name: "Prod"), names: ["app"], holds: []))
        #expect(none.commitBlock == .untracked)
    }

    @Test("A failed transaction is named before the other reasons")
    func abortedOutranksTheRest() {
        let id = UUID()
        let aborted = Self.hold(id, lane: "app", state: .aborted)
        let block = TransactionEndPrompt.commitBlock(
            holds: [aborted],
            untracked: true,
            effectiveLevel: { _ in .readOnly },
            busy: { _ in true }
        )

        #expect(block == .aborted)
    }

    @Test("One hold that cannot commit blocks Commit for all")
    func oneBlockedHoldBlocksAll() {
        let id = UUID()
        let block = TransactionEndPrompt.commitBlock(
            holds: [Self.hold(id, lane: "app"), Self.hold(id, lane: "logs", state: .aborted)],
            untracked: false,
            effectiveLevel: { _ in .silent },
            busy: { _ in false }
        )

        #expect(block == .aborted)
    }
}

private struct ManagedFloorPolicy: ManagedPolicyReading {
    let floor: SafeModeLevel

    func string(_ policy: ManagedPolicy) -> String? {
        policy == .minimumSafeModeLevel ? floor.rawValue : nil
    }
}
