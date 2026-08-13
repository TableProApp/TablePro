//
//  DestructiveAlertDefaultsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Destructive alert defaults")
@MainActor
struct DestructiveAlertDefaultsTests {
    private func returnKeyButtonCount(_ alert: NSAlert) -> Int {
        alert.buttons.filter { $0.keyEquivalent == "\r" }.count
    }

    // MARK: - Inspector Delete

    @Test("Inspector delete alert makes cancel the default button")
    func inspectorDeleteDefaultsToCancel() {
        let alert = InspectorDeleteConfirmation.makeAlert(messageText: "Delete this row?")
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[1].keyEquivalent == "\r")
        #expect(returnKeyButtonCount(alert) == 1)
    }

    @Test("Inspector delete alert marks the delete button destructive")
    func inspectorDeleteIsDestructive() {
        let alert = InspectorDeleteConfirmation.makeAlert(messageText: "Delete this column?")
        #expect(alert.buttons[0].hasDestructiveAction)
    }

    // MARK: - External Connection

    @Test("External connection alert makes cancel the default button")
    func externalConnectionDefaultsToCancel() {
        let connection = DatabaseConnection(name: "External", type: .mysql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: false)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[1].keyEquivalent == "\r")
        #expect(returnKeyButtonCount(alert) == 1)
    }

    @Test("Always Allow does not take the return key")
    func externalConnectionWithAlwaysAllow() {
        let connection = DatabaseConnection(name: "External", type: .postgresql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: true)
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons[1].keyEquivalent == "\r")
        #expect(alert.buttons[2].keyEquivalent == "")
        #expect(returnKeyButtonCount(alert) == 1)
    }

    @Test("Connecting is not presented as a destructive action")
    func externalConnectionIsNotDestructive() {
        let connection = DatabaseConnection(name: "External", type: .mysql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: false)
        #expect(alert.buttons[0].hasDestructiveAction == false)
    }

    // MARK: - Table Operations

    @Test("Drop alert makes cancel the default button")
    func dropAlertDefaultsToCancel() {
        let alert = NSAlert()
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: TableOperationPrompt(
                operationType: .drop,
                tableName: "users",
                tableCount: 1,
                cascadeSupported: false,
                foreignKeyDisableSupported: false
            ).confirmButtonTitle,
            cancelButton: String(localized: "Cancel")
        )
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\r")
        #expect(returnKeyButtonCount(alert) == 1)
    }
}
