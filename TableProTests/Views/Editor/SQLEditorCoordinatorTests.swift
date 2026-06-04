//
//  SQLEditorCoordinatorTests.swift
//  TableProTests
//
//  Tests for SQLEditorCoordinator destroy() lifecycle.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

private func makeEditorInlineSettings(
    enabled: Bool = true,
    inlineSuggestionsEnabled: Bool = true,
    providerType: AIProviderType? = .openAI
) -> AISettings {
    let provider = providerType.map {
        AIProviderConfig(type: $0, model: "test-model")
    }
    return AISettings(
        enabled: enabled,
        providers: provider.map { [$0] } ?? [],
        activeProviderID: provider?.id,
        inlineSuggestionsEnabled: inlineSuggestionsEnabled
    )
}

@MainActor
@Suite("SQLEditorCoordinator")
struct SQLEditorCoordinatorTests {
    @Test("Initial isDestroyed is false")
    func initialIsDestroyedIsFalse() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.isDestroyed == false)
    }

    @Test("destroy() sets isDestroyed to true")
    func destroySetsIsDestroyedTrue() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() can be called multiple times safely")
    func destroyIsIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() resets vimMode to .normal")
    func destroyResetsVimMode() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("Inline source policy disables suggestions when AI is off")
    func inlinePolicyReturnsOffWhenAIDisabled() {
        let settings = makeEditorInlineSettings(enabled: false)
        #expect(EditorInlineSourcePolicy.resolve(aiSettings: settings) == .off)
    }

    @Test("Inline source policy disables suggestions when inline setting is off")
    func inlinePolicyReturnsOffWhenInlineDisabled() {
        let settings = makeEditorInlineSettings(inlineSuggestionsEnabled: false)
        #expect(EditorInlineSourcePolicy.resolve(aiSettings: settings) == .off)
    }

    @Test("Inline source policy selects Copilot for active Copilot provider")
    func inlinePolicySelectsCopilotProvider() {
        let settings = makeEditorInlineSettings(providerType: .copilot)
        #expect(EditorInlineSourcePolicy.resolve(aiSettings: settings) == .copilot)
    }

    @Test("Inline source policy selects AI chat for non-Copilot provider")
    func inlinePolicySelectsAIProvider() {
        let settings = makeEditorInlineSettings(providerType: .openAI)
        #expect(EditorInlineSourcePolicy.resolve(aiSettings: settings) == .ai)
    }
}
