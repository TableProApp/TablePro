//
//  ConnectionEditorEngineNameTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineNameTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    @Test("A server is named after its host and database, or its host alone")
    func serverNames() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.host = " db.example.com "
        draft.database = "orders"
        #expect(ConnectionEditorEngine.suggestedName(draft, postgres) == "db.example.com/orders")

        draft.database = ""
        #expect(ConnectionEditorEngine.suggestedName(draft, postgres) == "db.example.com")
    }

    @Test("A form that names no server is named after its type")
    func typeNameWhenNothingIsTyped() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.host = ""
        draft.database = ""
        #expect(ConnectionEditorEngine.suggestedName(draft, postgres) == postgres.displayName)
    }

    @Test("A file type is named after its file, without the extension")
    func fileNames() throws {
        let sqlite = traits(.sqlite)
        try #require(sqlite.connectionMode == .fileBased)
        var draft = ConnectionDraft.new(type: .sqlite, traits: sqlite)
        draft.database = "/Users/me/Shop.sqlite"
        #expect(ConnectionEditorEngine.suggestedName(draft, sqlite) == "Shop")

        draft.database = ""
        #expect(ConnectionEditorEngine.suggestedName(draft, sqlite) == sqlite.displayName)
    }

    @Test("A typed name wins; an empty one saves as the saved name, else as the suggestion")
    func effectiveName() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.host = "db.example.com"
        var context = EditorContext()

        draft.name = "   "
        #expect(ConnectionEditorEngine.effectiveName(draft, postgres, context) == "db.example.com")

        context.savedName = "Orders"
        #expect(ConnectionEditorEngine.effectiveName(draft, postgres, context) == "Orders")
        #expect(ConnectionEditorEngine.edits(draft, postgres, originalTraits: postgres, context).name == "Orders")

        draft.name = "Billing"
        #expect(ConnectionEditorEngine.effectiveName(draft, postgres, context) == "Billing")
    }

    @Test("No registered type ever raises an issue on Name")
    func nameNeverHasAnIssue() {
        for type in DatabaseType.allKnownTypes {
            let traits = traits(type)
            var draft = ConnectionDraft.new(type: type, traits: traits)
            draft.name = ""
            let issues = ConnectionEditorEngine.issues(draft, traits, EditorContext())
            #expect(!issues.contains { $0.row == .builtIn(.name) }, "\(type.rawValue)")
            #expect(!ConnectionEditorEngine.effectiveName(draft, traits, EditorContext()).isEmpty, "\(type.rawValue)")
        }
    }
}
