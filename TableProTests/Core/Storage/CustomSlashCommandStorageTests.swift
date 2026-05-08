//
//  CustomSlashCommandStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CustomSlashCommandStorage")
@MainActor
struct CustomSlashCommandStorageTests {
    private func makeStorage() -> CustomSlashCommandStorage {
        let suiteName = "com.TablePro.tests.CustomSlashCommandStorage.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults suite creation failed")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return CustomSlashCommandStorage(defaults: defaults)
    }

    @Test("add stores a new command")
    func addStoresCommand() throws {
        let storage = makeStorage()
        let command = CustomSlashCommand(name: "review", promptTemplate: "Review {{query}}")
        try storage.add(command)
        #expect(storage.commands.count == 1)
        #expect(storage.commands.first?.name == "review")
    }

    @Test("add throws on duplicate name regardless of case")
    func addRejectsDuplicateName() throws {
        let storage = makeStorage()
        try storage.add(CustomSlashCommand(name: "review", promptTemplate: "x"))

        #expect(throws: CustomSlashCommandError.self) {
            try storage.add(CustomSlashCommand(name: "REVIEW", promptTemplate: "y"))
        }
        #expect(storage.commands.count == 1)
    }

    @Test("isDuplicate ignores the command being edited")
    func isDuplicateExcludesSelf() throws {
        let storage = makeStorage()
        let command = CustomSlashCommand(name: "review", promptTemplate: "x")
        try storage.add(command)
        #expect(storage.isDuplicate("review", excluding: command.id) == false)
        #expect(storage.isDuplicate("review") == true)
    }

    @Test("update rejects rename to an existing command's name")
    func updateRejectsCollidingRename() throws {
        let storage = makeStorage()
        try storage.add(CustomSlashCommand(name: "review", promptTemplate: "x"))
        let second = CustomSlashCommand(name: "summarize", promptTemplate: "y")
        try storage.add(second)

        var renamed = second
        renamed.name = "REVIEW"

        #expect(throws: CustomSlashCommandError.self) {
            try storage.update(renamed)
        }
        #expect(storage.command(named: "summarize") != nil)
    }

    @Test("update preserves the same command across rename without collision")
    func updateAllowsNonCollidingRename() throws {
        let storage = makeStorage()
        let original = CustomSlashCommand(name: "review", promptTemplate: "x")
        try storage.add(original)

        var renamed = original
        renamed.name = "audit"
        try storage.update(renamed)
        #expect(storage.command(named: "audit") != nil)
        #expect(storage.command(named: "review") == nil)
    }
}
