//
//  ManualCommitMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ManualCommitMenuTests {
    private func databaseMenu() throws -> NSMenu {
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings()).bar
        return try #require(bar.items.first { $0.title == String(localized: "Database") }?.submenu)
    }

    private func enabled(_ selector: Selector, _ context: MenuValidationContext) -> Bool {
        MainSplitViewController.isEnabled(selector, context: context)
    }

    @Test("Manual Commit, its footnotes, Commit Transaction and Roll Back Transaction follow Safe Mode Level")
    func itemsFollowSafeModeLevel() throws {
        let items = try databaseMenu().items
        let safeMode = try #require(items.firstIndex { $0.title == String(localized: "Safe Mode Level") })
        try #require(safeMode + 5 < items.count)

        #expect(items[safeMode + 1].title == String(localized: "Manual Commit"))
        #expect(items[safeMode + 1].action == #selector(MainSplitViewController.toggleManualCommit(_:)))
        #expect(items[safeMode + 2].identifier == DatabaseMenuBuilder.manualCommitFootnoteIdentifier)
        #expect(items[safeMode + 2].isHidden)
        #expect(items[safeMode + 3].identifier == DatabaseMenuBuilder.manualCommitUnavailableFootnoteIdentifier)
        #expect(items[safeMode + 3].attributedTitle?.string.replacingOccurrences(of: "\n", with: " ")
            == ManualCommit.unavailableExplanation)
        #expect(items[safeMode + 3].isHidden)
        #expect(items[safeMode + 4].title == String(localized: "Commit Transaction"))
        #expect(items[safeMode + 4].action == #selector(MainSplitViewController.commitOpenTransaction(_:)))
        #expect(items[safeMode + 5].title == String(localized: "Roll Back Transaction"))
        #expect(items[safeMode + 5].action == #selector(MainSplitViewController.rollBackOpenTransaction(_:)))
    }

    @Test("Commit and Roll Back Transaction are Keyboard rows with no default chord")
    func transactionCommandsShipUnbound() throws {
        for action in [ShortcutAction.commitTransaction, .rollbackTransaction] {
            #expect(KeyboardSettings.defaultShortcuts[action] == nil)
            let item = try #require(try databaseMenu().items.first { $0.identifier == MenuItemFactory.identifier(for: action) })
            #expect(item.keyEquivalent.isEmpty)
        }
    }

    @Test("Manual Commit needs a connection that can hold a transaction, and stays enabled while on")
    func manualCommitEnablement() {
        let toggle = #selector(MainSplitViewController.toggleManualCommit(_:))
        var context = MenuValidationContext()
        context.transaction.isAvailable = true
        context.transaction.canHoldTransactions = true
        #expect(!enabled(toggle, context))

        context.isConnected = true
        #expect(enabled(toggle, context))

        context.transaction.canHoldTransactions = false
        #expect(!enabled(toggle, context))

        context.transaction.isManualCommitOn = true
        #expect(enabled(toggle, context))
    }

    @Test("Where DDL commits on its own, Manual Commit is disabled with its footnote, even when stored on")
    func manualCommitUnavailable() {
        let toggle = #selector(MainSplitViewController.toggleManualCommit(_:))
        var context = MenuValidationContext()
        context.isConnected = true
        context.transaction.canHoldTransactions = true
        context.transaction.isManualCommitOn = true
        #expect(!enabled(toggle, context))
        #expect(MainSplitViewController.shownManualCommitFootnote(context.transaction, isConnected: true)
            == DatabaseMenuBuilder.manualCommitUnavailableFootnoteIdentifier)
        #expect(MainSplitViewController.shownManualCommitFootnote(context.transaction, isConnected: false) == nil)
    }

    @Test("The reporting footnote shows only where the engine can hold but its driver can't report, while off")
    func reportingFootnote() {
        var state = TransactionMenuState()
        state.isAvailable = true
        #expect(MainSplitViewController.shownManualCommitFootnote(state, isConnected: true)
            == DatabaseMenuBuilder.manualCommitFootnoteIdentifier)
        state.canHoldTransactions = true
        #expect(MainSplitViewController.shownManualCommitFootnote(state, isConnected: true) == nil)
        state.canHoldTransactions = false
        state.isManualCommitOn = true
        #expect(MainSplitViewController.shownManualCommitFootnote(state, isConnected: true) == nil)
    }

    @Test("Commit needs an open transaction it may commit; Roll Back needs any held transaction")
    func commitAndRollBackEnablement() {
        let commit = #selector(MainSplitViewController.commitOpenTransaction(_:))
        let rollBack = #selector(MainSplitViewController.rollBackOpenTransaction(_:))
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(commit, context))
        #expect(!enabled(rollBack, context))

        context.transaction.holdsTransaction = true
        #expect(!enabled(commit, context))
        #expect(enabled(rollBack, context))

        context.transaction.canCommit = true
        #expect(enabled(commit, context))
    }

    @Test("Commit is offered for an open hold below Read-Only, never for an aborted one")
    func commitFollowsSafeModeAndState() {
        let key = SessionTransactionTracker.Key(connectionId: UUID(), lane: nil)
        let open = SessionTransactionTracker.Hold(key: key, state: .open, revision: 1)
        let aborted = SessionTransactionTracker.Hold(key: key, state: .aborted, revision: 1)
        #expect(ConnectionTransactionActions.offersCommit(open, safeModeLevel: .silent))
        #expect(!ConnectionTransactionActions.offersCommit(open, safeModeLevel: .readOnly))
        #expect(!ConnectionTransactionActions.offersCommit(aborted, safeModeLevel: .silent))
    }
}
