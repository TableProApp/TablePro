//
//  AppleIntelligenceProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Apple Intelligence provider integration")
@MainActor
struct AppleIntelligenceProviderTests {
    @Test("Seeding is skipped when providers already exist")
    func seedSkippedWhenNotEmpty() {
        var settings = AISettings.default
        let existing = AIProviderConfig(id: UUID(), type: .claude, model: "claude-x")
        settings.providers = [existing]
        settings.activeProviderID = existing.id
        let result = AppSettingsManager.seedAppleIntelligenceIfEligible(settings)
        #expect(result.providers.count == 1)
        #expect(result.activeProviderID == existing.id)
        #expect(!result.providers.contains { $0.type == .appleIntelligence })
    }

    @Test("Seeding is idempotent when Apple Intelligence already present")
    func seedIdempotent() {
        var settings = AISettings.default
        let existing = AIProviderConfig(
            id: AIProviderType.appleIntelligenceSeededID,
            type: .appleIntelligence,
            model: AIProviderType.appleIntelligenceModelID
        )
        settings.providers = [existing]
        let result = AppSettingsManager.seedAppleIntelligenceIfEligible(settings)
        #expect(result.providers.filter { $0.type == .appleIntelligence }.count == 1)
    }

    @Test("Empty settings stay empty when the model is unavailable")
    func emptyStaysEmptyWhenUnavailable() {
        guard AppleIntelligenceAvailability.currentStatus() != .available else { return }
        let result = AppSettingsManager.seedAppleIntelligenceIfEligible(.default)
        #expect(result.providers.isEmpty)
    }

    @Test("Factory never falls back to an OpenAI-compatible transport for Apple Intelligence")
    func factoryGuard() {
        AIProviderRegistration.registerAll()
        let config = AIProviderConfig(
            id: UUID(),
            type: .appleIntelligence,
            model: AIProviderType.appleIntelligenceModelID
        )
        let transport = AIProviderFactory.createProvider(for: config, apiKey: nil)
        #expect(!(transport is OpenAICompatibleProvider))
        AIProviderFactory.invalidateCache(for: config.id)
    }

    @Test("Descriptor advertises chat only, with no remote model list")
    func descriptorCapabilities() {
        AIProviderRegistration.registerAll()
        let descriptor = AIProviderRegistry.shared.descriptor(for: AIProviderType.appleIntelligence.rawValue)
        #expect(descriptor != nil)
        #expect(descriptor?.capabilities.contains(.chat) == true)
        #expect(descriptor?.capabilities.contains(.models) == false)
    }
}
