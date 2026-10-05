//
//  AIChatViewModelImageGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIChatViewModelImageGateTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    /// The reported defect: the composer took an image for any model on a provider that accepts
    /// images at all, and a text-only model on a router then failed the turn.
    @Test("The composer refuses an image for a model its provider lists as text-only")
    func textOnlyModelRefusesImages() {
        let catalog = AIModelCatalog()
        let router = AIProviderConfig(preset: .requesty)
        catalog.store(providerID: router.id, models: [
            AIModelInfo(id: "alibaba/qwen-max", modalities: [.text]),
            AIModelInfo(id: "openai/gpt-5.5", modalities: [.text, .image])
        ])
        #expect(!AIChatViewModel.acceptsImages(config: router, model: "alibaba/qwen-max", catalog: catalog))
        #expect(AIChatViewModel.acceptsImages(config: router, model: "openai/gpt-5.5", catalog: catalog))
    }

    @Test("What one provider lists does not decide for another provider's model of the same name")
    func listsDoNotLeakBetweenProviders() {
        let catalog = AIModelCatalog()
        let router = AIProviderConfig(preset: .requesty)
        let local = AIProviderConfig(type: .custom, endpoint: "http://localhost:1234/v1")
        catalog.store(providerID: router.id, models: [AIModelInfo(id: "qwen", modalities: [.text])])
        #expect(!AIChatViewModel.acceptsImages(config: router, model: "qwen", catalog: catalog))
        #expect(AIChatViewModel.acceptsImages(config: local, model: "qwen", catalog: catalog))
    }

    @Test("A model the provider's list says nothing about still takes images")
    func unlistedModelTakesImages() {
        let catalog = AIModelCatalog()
        let local = AIProviderConfig(type: .llamaCpp)
        #expect(AIChatViewModel.acceptsImages(config: local, model: "llava", catalog: catalog))

        catalog.store(providerID: local.id, models: [AIModelInfo(id: "llava")])
        #expect(AIChatViewModel.acceptsImages(config: local, model: "llava", catalog: catalog))
    }

    @Test("A provider that takes no images refuses them whatever its model list says")
    func imagelessProviderRefuses() {
        let catalog = AIModelCatalog()
        let agent = AIProviderConfig(type: .claudeAgent)
        catalog.store(providerID: agent.id, models: [AIModelInfo(id: "opus", modalities: [.text, .image])])
        #expect(!AIChatViewModel.acceptsImages(config: agent, model: "opus", catalog: catalog))
    }
}
