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

    @Test("Manual Commit, its footnote, Commit Transaction and Roll Back Transaction follow Safe Mode Level")
    func itemsFollowSafeModeLevel() throws {
        let items = try databaseMenu().items
        let safeMode = try #require(items.firstIndex { $0.title == String(localized: "Safe Mode Level") })
        try #require(safeMode + 4 < items.count)

        #expect(items[safeMode + 1].title == String(localized: "Manual Commit"))
        #expect(items[safeMode + 1].action == #selector(MainSplitViewController.toggleManualCommit(_:)))
        #expect(items[safeMode + 2].identifier == DatabaseMenuBuilder.manualCommitFootnoteIdentifier)
        #expect(items[safeMode + 2].isHidden)
        #expect(items[safeMode + 3].title == String(localized: "Commit Transaction"))
        #expect(items[safeMode + 3].action == #selector(MainSplitViewController.commitOpenTransaction(_:)))
        #expect(items[safeMode + 4].title == String(localized: "Roll Back Transaction"))
        #expect(items[safeMode + 4].action == #selector(MainSplitViewController.rollBackOpenTransaction(_:)))
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
        context.transaction.canHoldTransactions = true
        #expect(!enabled(toggle, context))

        context.isConnected = true
        #expect(enabled(toggle, context))

        context.transaction.canHoldTransactions = false
        #expect(!enabled(toggle, context))

        context.transaction.isManualCommitOn = true
        #expect(enabled(toggle, context))
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
