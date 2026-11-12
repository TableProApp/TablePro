//
//  AIChatViewModelProviderSettingsTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

// Claude Agent lists its models without a network call.
private let claudeAgentProvider = AIProviderConfig(
    id: UUID(uuidString: "6B1E4F44-31D8-4C47-9B0B-3F0C2A9D1E01") ?? UUID(),
    type: .claudeAgent,
    model: "sonnet"
)

// Port 9 refuses the connection at once, so the model list fails without a timeout.
private let unreachableProvider = AIProviderConfig(
    id: UUID(uuidString: "6B1E4F44-31D8-4C47-9B0B-3F0C2A9D1E02") ?? UUID(),
    type: .custom,
    model: "model-a",
    endpoint: "http://127.0.0.1:9/v1"
)

extension GlobalStateSuites {
    @Suite(.appSettings {
        $0.ai.enabled = true
        $0.ai.providers = [claudeAgentProvider]
        $0.ai.activeProviderID = claudeAgentProvider.id
    })
    @MainActor
    struct AIChatViewModelProviderSettingsTests {
        private static let agent = claudeAgentProvider

        private func settingsSettle(_ viewModel: AIChatViewModel) async throws {
            let revision = viewModel.providerSettingsRevision
            AppServices.live.appEvents.aiProviderSaved.send(UUID())
            try await waitUntil { viewModel.providerSettingsRevision > revision }
        }

        @Test("A chat panel pick whose provider was removed is cleared when AI settings change")
        func removedProviderPickIsCleared() async throws {
            let viewModel = AIChatViewModel()
            viewModel.selectedProviderId = UUID()
            viewModel.selectedModel = "muse-spark-1.3"

            AppServices.live.appEvents.aiSettingsChanged.send(())
            try await settingsSettle(viewModel)

            #expect(viewModel.selectedProviderId == nil)
            #expect(viewModel.selectedModel == nil)
        }

        @Test("A chat panel pick whose provider is still configured is kept")
        func configuredProviderPickIsKept() async throws {
            let viewModel = AIChatViewModel()
            viewModel.selectedProviderId = Self.agent.id
            viewModel.selectedModel = "opus"

            AppServices.live.appEvents.aiSettingsChanged.send(())
            try await settingsSettle(viewModel)

            #expect(viewModel.selectedProviderId == Self.agent.id)
            #expect(viewModel.selectedModel == "opus")
        }

        /// A key fixed in Settings changes nothing the provider list shows, and the panel kept the
        /// list it had fetched with the rejected key.
        @Test("Saving a provider makes the chat panel fetch its model list again")
        func savedProviderListIsFetchedAgain() async throws {
            let viewModel = AIChatViewModel()
            await viewModel.loadAvailableModels()
            #expect(viewModel.availableModels[Self.agent.id] == ["opus", "sonnet", "haiku"])
            #expect(!viewModel.modelListIsStale(for: Self.agent))

            let revision = viewModel.providerSettingsRevision
            AppServices.live.appEvents.aiProviderSaved.send(Self.agent.id)
            try await waitUntil { viewModel.providerSettingsRevision > revision }
            #expect(viewModel.modelListIsStale(for: Self.agent))

            await viewModel.loadAvailableModels()
            #expect(!viewModel.modelListIsStale(for: Self.agent))
        }

        /// A server that cannot answer was asked again on every connection switch, and the whole
        /// panel waited on it each time.
        @Test("A model list that failed to load is not fetched again until the provider changes", .appSettings {
            $0.ai.providers = [unreachableProvider]
        })
        func failedListIsNotFetchedAgain() async {
            let viewModel = AIChatViewModel()
            await viewModel.loadAvailableModels()
            #expect(viewModel.availableModels[unreachableProvider.id] == [])
            #expect(!viewModel.modelListIsStale(for: unreachableProvider))

            var moved = unreachableProvider
            moved.endpoint = "http://127.0.0.1:9/v2"
            #expect(viewModel.modelListIsStale(for: moved))
        }

        @Test("A model list depends on the Base URL and the preset, not on the model picked")
        func listSourceTracksWhatTheListDependsOn() {
            let saved = AIProviderConfig(preset: .meta)
            let fetched = AIModelListSource(config: saved)

            var otherModel = saved
            otherModel.model = "muse-wonder-1.0"
            #expect(AIModelListSource(config: otherModel) == fetched)

            var otherServer = saved
            otherServer.endpoint = "https://gateway.example/meta"
            #expect(AIModelListSource(config: otherServer) != fetched)

            var noPreset = saved
            noPreset.presetID = nil
            #expect(AIModelListSource(config: noPreset) != fetched)
        }
    }
}
