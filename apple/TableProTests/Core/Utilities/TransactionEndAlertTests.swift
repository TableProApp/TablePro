//
//  TransactionEndAlertTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct TransactionEndAlertTests {
    private static let escape = "\u{1B}"
    private static let returnKey = "\r"

    private static func prompt(state: SessionTransactionTracker.State) throws -> TransactionEndPrompt {
        let hold = SessionTransactionTracker.Hold(key: .init(connectionId: UUID(), lane: nil), state: state, revision: 0)
        return try #require(TransactionEndPrompt.make(
            action: .disconnect(name: "Prod"),
            names: ["app"],
            holds: [hold],
            effectiveLevel: { _ in .silent },
            busy: { _ in false }
        ))
    }

    // The Save alert's order: the default first, Cancel second, the destructive choice third.
    @Test("Commit, Cancel, then Roll Back, in the order NSDocument uses for Save")
    func buttonOrder() throws {
        let alert = AlertHelper.makeTransactionEndAlert(try Self.prompt(state: .open))

        #expect(alert.buttons.map { $0.title } == ["Commit", "Cancel", "Roll Back"])
        #expect(alert.alertStyle == .warning)
    }

    @Test("Return commits, Escape cancels, and Roll Back takes a deliberate click")
    func keyBindings() throws {
        let alert = AlertHelper.makeTransactionEndAlert(try Self.prompt(state: .open))

        #expect(alert.buttons[0].keyEquivalent == Self.returnKey)
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(alert.buttons[2].keyEquivalent == "")
        #expect(alert.buttons.filter { $0.keyEquivalent == Self.returnKey }.count == 1)
        #expect(alert.buttons.filter { $0.keyEquivalent == Self.escape }.count == 1)
    }

    @Test("Roll Back is the destructive button and Commit is not")
    func rollBackIsDestructive() throws {
        let alert = AlertHelper.makeTransactionEndAlert(try Self.prompt(state: .open))

        #expect(alert.buttons[2].hasDestructiveAction)
        #expect(!alert.buttons[0].hasDestructiveAction)
        #expect(!alert.buttons[1].hasDestructiveAction)
    }

    @Test("Each button maps to its answer")
    func answers() {
        #expect(AlertHelper.transactionEndAnswer(to: .alertFirstButtonReturn, offersCommit: true) == .commit)
        #expect(AlertHelper.transactionEndAnswer(to: .alertSecondButtonReturn, offersCommit: true) == .cancel)
        #expect(AlertHelper.transactionEndAnswer(to: .alertThirdButtonReturn, offersCommit: true) == .rollBack)
        #expect(AlertHelper.transactionEndAnswer(to: .abort, offersCommit: true) == .cancel)
    }

    @Test("Without Commit, the roll-back alert keeps Escape on Cancel and takes Return off its button")
    func rollBackOnlyAlert() throws {
        let prompt = try Self.prompt(state: .aborted)
        let alert = AlertHelper.makeTransactionEndAlert(prompt)

        #expect(alert.buttons.map { $0.title } == ["Disconnect", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(AlertHelper.transactionEndAnswer(to: .alertFirstButtonReturn, offersCommit: false) == .rollBack)
        #expect(AlertHelper.transactionEndAnswer(to: .alertSecondButtonReturn, offersCommit: false) == .cancel)
        #expect(AlertHelper.transactionEndAnswer(to: .alertThirdButtonReturn, offersCommit: false) == .cancel)
    }
}
