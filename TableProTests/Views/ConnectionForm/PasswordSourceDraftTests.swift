//
//  PasswordSourceDraftTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PasswordSourceDraft")
struct PasswordSourceDraftTests {
    @Test("Every source round trips through the form and back unchanged", arguments: [
        PasswordSource.file(path: "~/.pgpass-ish"),
        PasswordSource.env(variable: "DB_PASSWORD"),
        PasswordSource.command(shell: "op read op://v/db/password"),
        PasswordSource.sharedTemplate,
        PasswordSource.onePassword(reference: "op://Vault/Database/password"),
        PasswordSource.vault(path: "secret/data/db", field: "password"),
        PasswordSource.awsSecretsManager(secretId: "prod/db", jsonKey: "password"),
        PasswordSource.awsSecretsManager(secretId: "prod/db", jsonKey: nil),
    ])
    func roundTrips(source: PasswordSource) {
        let draft = PasswordSourceDraft(source: source, promptsForPassword: false)
        #expect(draft.passwordSource == source)
    }

    @Test("No source and no prompt is the Keychain")
    func defaultsToKeychain() {
        let draft = PasswordSourceDraft(source: nil, promptsForPassword: false)
        #expect(draft.mode == .keychain)
        #expect(draft.passwordSource == nil)
        #expect(!draft.promptsForPassword)
    }

    @Test("A prompting connection loads as the prompt mode")
    func loadsPrompt() {
        let draft = PasswordSourceDraft(source: nil, promptsForPassword: true)
        #expect(draft.mode == .prompt)
        #expect(draft.passwordSource == nil)
        #expect(draft.promptsForPassword)
    }

    @Test("A source wins over a stale prompt flag, because that is what the connect path does")
    func sourceBeatsPromptFlag() {
        let draft = PasswordSourceDraft(source: .sharedTemplate, promptsForPassword: true)
        #expect(draft.mode == .sharedTemplate)
        #expect(!draft.promptsForPassword)
    }

    @Test("An external mode with an empty field produces no source and says why")
    func emptyExternalFieldIsAnIssue() {
        var draft = PasswordSourceDraft()
        draft.mode = .command
        #expect(draft.passwordSource == nil)
        #expect(draft.validationIssue != nil)

        draft.command = "  "
        #expect(draft.passwordSource == nil)
        #expect(draft.validationIssue != nil)

        draft.command = "printf secret"
        #expect(draft.passwordSource == .command(shell: "printf secret"))
        #expect(draft.validationIssue == nil)
    }

    @Test("The shared template needs nothing filled in here, so it never blocks a save")
    func sharedTemplateNeedsNoField() {
        var draft = PasswordSourceDraft()
        draft.mode = .sharedTemplate
        #expect(draft.passwordSource == .sharedTemplate)
        #expect(draft.validationIssue == nil)
    }

    @Test("Vault falls back to the password field when the field box is cleared")
    func vaultFieldFallsBack() {
        var draft = PasswordSourceDraft()
        draft.mode = .vault
        draft.vaultPath = "secret/data/db"
        draft.vaultField = ""
        #expect(draft.passwordSource == .vault(path: "secret/data/db", field: "password"))
    }

    @Test("Switching modes keeps what was typed in the other one")
    func keepsFieldsAcrossModeSwitch() {
        var draft = PasswordSourceDraft(source: .command(shell: "printf a"), promptsForPassword: false)
        draft.mode = .onePassword
        draft.onePasswordReference = "op://v/db/password"
        draft.mode = .command
        #expect(draft.passwordSource == .command(shell: "printf a"))
    }

    @Test("Keychain and prompt are the only modes TablePro answers itself")
    func externalModes() {
        #expect(!PasswordSourceMode.keychain.isExternal)
        #expect(!PasswordSourceMode.prompt.isExternal)
        for mode in PasswordSourceMode.allCases where mode != .keychain && mode != .prompt {
            #expect(mode.isExternal)
        }
    }
}
