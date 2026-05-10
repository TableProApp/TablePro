//
//  AppSettingsManagerMigrationTests.swift
//  TableProTests
//
//  Verifies the AISettings upgrade path that auto-picks an active
//  provider when older settings JSON didn't have the concept.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AppSettingsManager.migrateAI")
@MainActor
struct AppSettingsManagerMigrationTests {
    private func makeProvider(name: String, type: AIProviderType = .claude) -> AIProviderConfig {
        AIProviderConfig(name: name, type: type)
    }

    @Test("No providers: leaves activeProviderID nil")
    func emptyProvidersStaysNil() {
        let input = AISettings(providers: [], activeProviderID: nil)
        let migrated = AppSettingsManager.migrateAI(input)
        #expect(migrated.activeProviderID == nil)
        #expect(migrated.providers.isEmpty)
    }

    @Test("activeProviderID already set: returns settings unchanged")
    func alreadySetReturnsUnchanged() {
        let provider = makeProvider(name: "Claude")
        let other = makeProvider(name: "Other")
        let input = AISettings(providers: [other, provider], activeProviderID: provider.id)
        let migrated = AppSettingsManager.migrateAI(input)
        #expect(migrated.activeProviderID == provider.id)
        #expect(migrated == input)
    }

    @Test("activeProviderID nil with one provider: picks that provider")
    func picksOnlyProvider() {
        let provider = makeProvider(name: "OpenAI", type: .openAI)
        let input = AISettings(providers: [provider], activeProviderID: nil)
        let migrated = AppSettingsManager.migrateAI(input)
        #expect(migrated.activeProviderID == provider.id)
    }

    @Test("activeProviderID nil with multiple providers: picks the first")
    func picksFirstWhenMultiple() {
        let first = makeProvider(name: "First")
        let second = makeProvider(name: "Second")
        let third = makeProvider(name: "Third")
        let input = AISettings(providers: [first, second, third], activeProviderID: nil)
        let migrated = AppSettingsManager.migrateAI(input)
        #expect(migrated.activeProviderID == first.id)
    }

    @Test("Migration is idempotent")
    func idempotent() {
        let provider = makeProvider(name: "Claude")
        let input = AISettings(providers: [provider], activeProviderID: nil)
        let once = AppSettingsManager.migrateAI(input)
        let twice = AppSettingsManager.migrateAI(once)
        #expect(once == twice)
        #expect(twice.activeProviderID == provider.id)
    }

    @Test("Migration preserves other settings fields")
    func preservesOtherFields() {
        let provider = makeProvider(name: "Claude")
        let input = AISettings(
            enabled: false,
            providers: [provider],
            activeProviderID: nil,
            inlineSuggestionsEnabled: true,
            includeSchema: false,
            includeCurrentQuery: false,
            includeQueryResults: true,
            maxSchemaTables: 50,
            defaultConnectionPolicy: .never
        )
        let migrated = AppSettingsManager.migrateAI(input)
        #expect(migrated.enabled == false)
        #expect(migrated.inlineSuggestionsEnabled == true)
        #expect(migrated.includeSchema == false)
        #expect(migrated.includeCurrentQuery == false)
        #expect(migrated.includeQueryResults == true)
        #expect(migrated.maxSchemaTables == 50)
        #expect(migrated.defaultConnectionPolicy == .never)
    }
}
