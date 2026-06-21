//
//  SQLCompletionAdapterLifecycleTests.swift
//  TableProTests
//
//  Guards the invariants behind the autocomplete delegate-lifetime fix (#1731):
//  the completion engine produces keyword suggestions before any schema is
//  attached, and reconfiguring the adapter across nil/non-nil schema transitions
//  keeps it functional. The SwiftUI onDisappear/onAppear delegate attachment that
//  caused the original dropout is an AppKit lifecycle behaviour and is not
//  deterministically unit-testable; these tests cover the logic the fix relies on.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Completion Adapter Lifecycle")
struct SQLCompletionAdapterLifecycleTests {
    @Test("engine returns keyword completions with no schema provider")
    func keywordsAvailableWithoutSchema() async {
        let engine = CompletionEngine(schemaProvider: nil, databaseType: .postgresql)
        let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
        #expect(context?.items.contains { $0.label == "SELECT" } == true)
    }

    @Test("engine returns keyword completions with no schema and no database type")
    func keywordsAvailableWithoutSchemaOrDatabaseType() async {
        let engine = CompletionEngine(schemaProvider: nil, databaseType: nil)
        let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
        #expect(context?.items.contains { $0.label == "SELECT" } == true)
    }

    @MainActor
    @Test("configure across nil and non-nil schema keeps the adapter functional")
    func configureAcrossSchemaTransitionsKeepsAdapterUsable() {
        let adapter = SQLCompletionAdapter(schemaProvider: nil, databaseType: nil)
        #expect(!adapter.completionTriggerCharacters().isEmpty)

        adapter.configure(schemaProvider: nil, databaseType: .postgresql)
        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        adapter.configure(schemaProvider: nil, databaseType: .mysql)

        #expect(!adapter.completionTriggerCharacters().isEmpty)
    }
}
