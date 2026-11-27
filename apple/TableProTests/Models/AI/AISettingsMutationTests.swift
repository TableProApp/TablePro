import Combine
import Foundation
@testable import TablePro
import Testing

struct AISettingsMutationTests {
    private let first = AIProviderConfig(name: "First", type: .openAI)
    private let second = AIProviderConfig(name: "Second", type: .claude)

    @Test("Upserting a new provider appends it and makes it active when none is")
    func upsertingAppendsAndActivates() {
        let settings = AISettings(providers: [first]).upserting(second, makeActiveIfNone: true)
        #expect(settings.providers.map(\.id) == [first.id, second.id])
        #expect(settings.activeProviderID == second.id)
    }

    @Test("Upserting keeps the active provider that already answers")
    func upsertingKeepsTheActiveProvider() {
        let settings = AISettings(providers: [first], activeProviderID: first.id)
            .upserting(second, makeActiveIfNone: true)
        #expect(settings.activeProviderID == first.id)
    }

    // Another Mac can remove the active provider, which leaves an id that answers to nothing.
    @Test("Upserting replaces an active id whose provider is gone")
    func upsertingReplacesADanglingActiveID() {
        let settings = AISettings(providers: [], activeProviderID: UUID())
            .upserting(first, makeActiveIfNone: true)
        #expect(settings.activeProviderID == first.id)
    }

    @Test("Upserting without activation leaves the active provider alone")
    func upsertingWithoutActivation() {
        let settings = AISettings(providers: []).upserting(first, makeActiveIfNone: false)
        #expect(settings.providers == [first])
        #expect(settings.activeProviderID == nil)
    }

    @Test("Upserting a saved provider replaces it in place")
    func upsertingReplacesInPlace() {
        var renamed = first
        renamed.name = "Renamed"
        let settings = AISettings(providers: [first, second]).upserting(renamed, makeActiveIfNone: false)
        #expect(settings.providers.map(\.name) == ["Renamed", "Second"])
    }

    @Test("Removing the active provider clears the active id in the same value")
    func removingTheActiveProvider() {
        let settings = AISettings(providers: [first, second], activeProviderID: second.id).removingProvider(second.id)
        #expect(settings.providers == [first])
        #expect(settings.activeProviderID == nil)
    }

    @Test("Removing another provider keeps the active one")
    func removingAnotherProvider() {
        let settings = AISettings(providers: [first, second], activeProviderID: first.id).removingProvider(second.id)
        #expect(settings.providers == [first])
        #expect(settings.activeProviderID == first.id)
    }

    @Test("Replacing a provider changes only that provider")
    func replacingAProvider() {
        var edited = second
        edited.model = "claude-opus-5"
        let settings = AISettings(providers: [first, second], activeProviderID: first.id).replacingProvider(edited)
        #expect(settings.providers == [first, edited])
        #expect(settings.activeProviderID == first.id)
    }

    // A page still open on a provider another Mac removed must not bring it back with its next edit.
    @Test("Replacing a provider that is gone changes nothing")
    func replacingAMissingProvider() {
        let settings = AISettings(providers: [first])
        #expect(settings.replacingProvider(second) == settings)
    }

    @Test("The schema table limit stays inside its range")
    func schemaTableLimitIsClamped() {
        #expect(AISettings(maxSchemaTables: -5).clampedMaxSchemaTables == 1)
        #expect(AISettings(maxSchemaTables: 0).clampedMaxSchemaTables == 1)
        #expect(AISettings(maxSchemaTables: 20).clampedMaxSchemaTables == 20)
        #expect(AISettings(maxSchemaTables: 5_000).clampedMaxSchemaTables == 100)
    }

    // prefix(_:) traps on a negative count, and a synced value can be anything.
    @Test("A negative schema table limit never reaches prefix")
    func negativeSchemaTableLimitDoesNotTrap() {
        let tables = Array(0..<10)
        let settings = AISettings(maxSchemaTables: -1)
        #expect(tables.prefix(settings.clampedMaxSchemaTables) == [0])
    }

    @MainActor
    @Test("Removing a provider is one settings write that also closes its page")
    func paneRemovalWritesOnceAndPops() {
        let slice = SettingsSlice(AISettings(providers: [first, second], activeProviderID: second.id))
        let navigation = SettingsNavigationModel(initial: SettingsLocation(route: .aiProvider(second.id)))
        var writes = 0
        let observation = slice.objectWillChange.sink { _ in writes += 1 }
        let model = AISettingsPaneModel()
        model.setHasKey(true, for: second.id)

        model.remove(second, from: slice, navigation: navigation)

        #expect(slice.value.providers == [first])
        #expect(slice.value.activeProviderID == nil)
        #expect(writes == 1)
        #expect(navigation.location == .root(.ai))
        #expect(!model.hasKey(second.id))
        observation.cancel()
    }

    @MainActor
    @Test("An account is checked again only after a minute")
    func accountChecksAreThrottled() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let model = AISettingsPaneModel(now: { clock })
        #expect(model.claimAccountChecks([.claudeAgent, .chatgptCodex]) == [.claudeAgent, .chatgptCodex])
        clock += 30
        #expect(model.claimAccountChecks([.claudeAgent, .chatgptCodex]).isEmpty)
        clock += 31
        #expect(model.claimAccountChecks([.claudeAgent]) == [.claudeAgent])
    }

    @Test("The tool call limit stays inside its range")
    func toolCallLimitIsClamped() {
        #expect(AISettings(maxToolRoundtrips: 0).clampedMaxToolRoundtrips == AISettings.maxToolRoundtripsRange.lowerBound)
        #expect(AISettings(maxToolRoundtrips: 9_999).clampedMaxToolRoundtrips == AISettings.maxToolRoundtripsRange.upperBound)
        #expect(AISettings(maxToolRoundtrips: 40, maxToolRoundtripsEnabled: false).effectiveMaxToolRoundtrips == nil)
        #expect(AISettings(maxToolRoundtrips: 40).effectiveMaxToolRoundtrips == 40)
    }
}
