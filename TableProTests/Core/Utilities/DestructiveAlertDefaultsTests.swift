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
    private static let escape = "\u{1B}"
    private static let returnKey = "\r"

    private func buttonCount(_ alert: NSAlert, withKeyEquivalent key: String) -> Int {
        alert.buttons.filter { $0.keyEquivalent == key }.count
    }

    // MARK: - Inspector Delete

    @Test("Inspector delete alert keeps Escape on cancel and takes Return off delete")
    func inspectorDeleteBindings() {
        let alert = InspectorDeleteConfirmation.makeAlert(messageText: "Delete this row?")
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].keyEquivalent != Self.returnKey)
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(buttonCount(alert, withKeyEquivalent: Self.returnKey) == 0)
        #expect(buttonCount(alert, withKeyEquivalent: Self.escape) == 1)
    }

    @Test("Inspector delete alert marks the delete button destructive")
    func inspectorDeleteIsDestructive() {
        let alert = InspectorDeleteConfirmation.makeAlert(messageText: "Delete this column?")
        #expect(alert.buttons[0].hasDestructiveAction)
    }

    // MARK: - External Connection

    @Test("External connection alert keeps Escape on cancel and takes Return off connect")
    func externalConnectionBindings() {
        let connection = DatabaseConnection(name: "External", type: .mysql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: false)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(buttonCount(alert, withKeyEquivalent: Self.returnKey) == 0)
    }

    @Test("Always Allow does not take the return key and Escape survives")
    func externalConnectionWithAlwaysAllow() {
        let connection = DatabaseConnection(name: "External", type: .postgresql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: true)
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(alert.buttons[2].keyEquivalent != Self.returnKey)
        #expect(buttonCount(alert, withKeyEquivalent: Self.returnKey) == 0)
    }

    @Test("Connecting is not presented as a destructive action")
    func externalConnectionIsNotDestructive() {
        let connection = DatabaseConnection(name: "External", type: .mysql)
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: false)
        #expect(alert.buttons[0].hasDestructiveAction == false)
    }

    // MARK: - Table Operations

    @Test("Drop alert keeps Escape on cancel and takes Return off drop")
    func dropAlertBindings() {
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
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent != Self.returnKey)
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(buttonCount(alert, withKeyEquivalent: Self.returnKey) == 0)
    }

    /// The binding is written rather than inferred, because `NSAlert` only recognises a cancel
    /// button by its English title and a localized build stops matching.
    @Test("A localized cancel title still carries Escape")
    func localizedCancelKeepsEscape() {
        let alert = NSAlert()
        AlertHelper.addConfirmAndCancel(to: alert, confirmButton: "Drop", cancelButton: "Huỷ")
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(buttonCount(alert, withKeyEquivalent: Self.escape) == 1)
    }
}
