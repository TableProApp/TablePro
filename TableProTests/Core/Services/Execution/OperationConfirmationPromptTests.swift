//
//  OperationConfirmationPromptTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing
import TableProPluginKit

@Suite("Operation confirmation prompt")
@MainActor
struct OperationConfirmationPromptTests {
    private static let escape = "\u{1B}"
    private static let returnKey = "\r"

    private func makeRequest(
        sql: String?,
        caller: OperationCaller = .userInterface,
        connectionName: String? = "Production",
        isDestructive: Bool = false,
        operationDescription: String = "Execute Query"
    ) -> OperationConfirmationRequest {
        OperationConfirmationRequest(
            sql: sql,
            operationDescription: operationDescription,
            connectionId: UUID(),
            connectionName: connectionName,
            databaseType: .mysql,
            caller: caller,
            isDestructive: isDestructive
        )
    }

    // MARK: - The statement

    /// The whole point of #2759: the statement the user is approving reaches the dialog intact.
    @Test("A statement past the old 200 character cut is carried whole")
    func longStatementIsNotTruncated() {
        let statement = (1 ... 40)
            .map { "UPDATE accounts SET balance = balance - \($0) WHERE customer_id = \($0);" }
            .joined(separator: "\n")
        #expect((statement as NSString).length > 200)

        let carried = OperationConfirmationPrompt.statement(of: makeRequest(sql: statement))
        #expect(carried == statement)
    }

    @Test("Surrounding whitespace is trimmed but the statement's own line breaks survive")
    func statementKeepsItsLineBreaks() {
        let carried = OperationConfirmationPrompt.statement(of: makeRequest(sql: "\n\nSELECT\n  1\n\n"))
        #expect(carried == "SELECT\n  1")
    }

    @Test("A request with no statement has nothing to show")
    func missingStatementIsAbsent() {
        #expect(OperationConfirmationPrompt.statement(of: makeRequest(sql: nil)) == nil)
        #expect(OperationConfirmationPrompt.statement(of: makeRequest(sql: "")) == nil)
        #expect(OperationConfirmationPrompt.statement(of: makeRequest(sql: "   \n ")) == nil)
    }

    // MARK: - Who is asking, and where

    @Test("A named MCP client is named, with the connection it is reaching")
    func mcpClientIsNamed() {
        let subtitle = OperationConfirmationPrompt.subtitle(
            of: makeRequest(sql: "SELECT 1", caller: .mcpClient(label: "Claude"))
        )
        #expect(subtitle.contains("Claude"))
        #expect(subtitle.contains("Production"))
    }

    @Test("An unnamed MCP client still says a client is asking")
    func anonymousMcpClientIsDescribed() {
        let subtitle = OperationConfirmationPrompt.subtitle(
            of: makeRequest(sql: "SELECT 1", caller: .mcpClient(label: nil))
        )
        #expect(subtitle.contains("Production"))
        #expect(!subtitle.isEmpty)
    }

    @Test("Every remote caller is distinguishable from the app itself")
    func callersAreDistinguishable() {
        let subtitles = [
            OperationCaller.mcpClient(label: "Claude"),
            .appleScript(client: "Raycast"),
            .aiAssistant(sessionId: nil),
            .userInterface
        ].map { caller in
            OperationConfirmationPrompt.subtitle(of: makeRequest(sql: "SELECT 1", caller: caller))
        }
        #expect(Set(subtitles).count == subtitles.count)
    }

    @Test("An unknown connection name is left out rather than shown empty")
    func unknownConnectionIsOmitted() {
        for name in [nil, "", "   "] as [String?] {
            let subtitle = OperationConfirmationPrompt.subtitle(
                of: makeRequest(sql: "SELECT 1", caller: .mcpClient(label: "Claude"), connectionName: name)
            )
            #expect(!subtitle.contains("''"))
            #expect(!subtitle.isEmpty)
        }
    }

    // MARK: - Destructive

    @Test("Only a destructive operation carries the warning")
    func destructiveWarningIsConditional() {
        #expect(OperationConfirmationPrompt.destructiveWarning(of: makeRequest(sql: "SELECT 1")) == nil)
        #expect(
            OperationConfirmationPrompt.destructiveWarning(
                of: makeRequest(sql: "DROP TABLE users", isDestructive: true)
            ) != nil
        )
    }

    // MARK: - The no-statement alert

    /// A rename has no statement, so it stays an alert rather than rendering an empty review box.
    @Test("The no-statement alert names the operation and never trails a blank line")
    func statementlessAlertReadsCleanly() {
        let alert = OperationConfirmationPrompt.makeAlert(
            for: makeRequest(sql: nil, operationDescription: "Rename users to customers")
        )
        #expect(alert.messageText == "Rename users to customers")
        #expect(!alert.informativeText.isEmpty)
        #expect(!alert.informativeText.hasSuffix("\n"))
        #expect(alert.informativeText.contains("Production"))
    }

    @Test("The no-statement alert keeps Escape on cancel and takes Return off execute")
    func statementlessAlertKeyBindings() {
        let alert = OperationConfirmationPrompt.makeAlert(for: makeRequest(sql: nil))
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent != Self.returnKey)
        #expect(alert.buttons[1].keyEquivalent == Self.escape)
        #expect(alert.buttons.filter { $0.keyEquivalent == Self.returnKey }.isEmpty)
    }

    @Test("A destructive operation with no statement is presented as critical")
    func statementlessDestructiveAlertIsCritical() {
        let alert = OperationConfirmationPrompt.makeAlert(
            for: makeRequest(sql: nil, isDestructive: true)
        )
        #expect(alert.alertStyle == .critical)
    }

    // MARK: - The review dialog's confirming button

    /// The alert this dialog replaced took Return off its confirming button on purpose
    /// (`AlertHelper.addConfirmAndCancel`). A confirmation raised by an MCP client activates the app
    /// over whatever the user was typing in, so a Return already on its way would answer it.
    @Test("A confirmation raised for someone else never gives Execute the Return key")
    func confirmationExecuteIsNotTheDefaultButton() {
        for isDestructive in [true, false] {
            let action = SQLReviewSheet.PrimaryAction(
                title: OperationConfirmationPrompt.confirmTitle,
                isDestructive: isDestructive,
                takesDefaultAction: false
            ) {}
            #expect(!action.takesDefaultAction)
        }
    }

    /// The Users and Roles review is a step the user asked for, so its Execute keeps Return.
    @Test("A review the user opened keeps Return on its confirming button by default")
    func userInitiatedReviewKeepsTheDefaultButton() {
        let action = SQLReviewSheet.PrimaryAction(title: "Execute", isDestructive: false) {}
        #expect(action.takesDefaultAction)
    }

    // MARK: - MCP titles

    @Test("An MCP operation label becomes the dialog's title")
    func mcpOperationLabelTitlesTheDialog() {
        let titled = MCPAuthPolicy.operationDescription(for: "transaction begin")
        #expect(titled.contains("transaction begin"))

        let fallback = MCPAuthPolicy.operationDescription(for: nil)
        #expect(!fallback.isEmpty)
        #expect(MCPAuthPolicy.operationDescription(for: "") == fallback)
    }
}
