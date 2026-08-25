//
//  QueryCompletionAdapterLifecycleTests.swift
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

@Suite("Query Completion Adapter Lifecycle")
struct QueryCompletionAdapterLifecycleTests {
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
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: nil)
        #expect(!adapter.completionTriggerCharacters().isEmpty)

        adapter.configure(schemaProvider: nil, databaseType: .postgresql)
        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        adapter.configure(schemaProvider: nil, databaseType: .mysql)

        #expect(!adapter.completionTriggerCharacters().isEmpty)
    }

    /// Rebuilding the service drops the open completion session. A refresh in any window of the
    /// connection bumps the profile revision the editor's task keys on, so an unconditional
    /// rebuild closed the popup under whoever was typing.
    @MainActor
    @Test("configuring with unchanged inputs does not rebuild the service")
    func configureWithUnchangedInputsKeepsTheService() {
        let provider = SQLSchemaProvider()
        let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
        let profile = QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [],
            revision: "rev-1"
        )
        adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)
        let first = adapter.serviceIdentityForTesting

        adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)

        #expect(adapter.serviceIdentityForTesting == first)
    }

    @MainActor
    @Test("a changed profile revision rebuilds the service")
    func changedProfileRevisionRebuildsTheService() {
        let provider = SQLSchemaProvider()
        let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
        adapter.configure(
            schemaProvider: provider,
            databaseType: .postgresql,
            profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-1")
        )
        let first = adapter.serviceIdentityForTesting

        adapter.configure(
            schemaProvider: provider,
            databaseType: .postgresql,
            profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-2")
        )

        #expect(adapter.serviceIdentityForTesting != first)
    }

    @MainActor
    @Test("a changed schema provider rebuilds the service")
    func changedSchemaProviderRebuildsTheService() {
        let adapter = QueryCompletionAdapter(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        let first = adapter.serviceIdentityForTesting

        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)

        #expect(adapter.serviceIdentityForTesting != first)
    }
}
