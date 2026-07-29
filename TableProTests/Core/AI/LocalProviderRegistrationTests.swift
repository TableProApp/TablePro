//
//  LocalProviderRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Local OpenAI-compatible provider registration")
struct LocalProviderRegistrationTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func descriptor(for type: AIProviderType) -> AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: type.rawValue)
    }

    @Test("llama.cpp is a known local provider with no auth and the default llama-server endpoint")
    func llamaCppType() {
        #expect(AIProviderType.llamaCpp.authStyle == .none)
        #expect(AIProviderType.allCases.contains(.llamaCpp))
        #expect(AIProviderType(rawValue: "llamaCpp") == .llamaCpp)
        #expect(AIProviderType.llamaCpp.displayName == "llama.cpp")
        #expect(AIProviderType.llamaCpp.defaultEndpoint == "http://localhost:8080")
    }

    @Test("MLX is a known local provider with no auth and the default mlx_lm.server endpoint")
    func mlxType() {
        #expect(AIProviderType.mlx.authStyle == .none)
        #expect(AIProviderType.allCases.contains(.mlx))
        #expect(AIProviderType(rawValue: "mlx") == .mlx)
        #expect(AIProviderType.mlx.displayName == "MLX")
        #expect(AIProviderType.mlx.defaultEndpoint == "http://localhost:8080")
    }

    @Test("Local providers register OpenAI-compatible descriptors that fetch models and take an endpoint")
    func descriptorCapabilities() {
        for type in [AIProviderType.llamaCpp, .mlx] {
            let provider = descriptor(for: type)
            #expect(provider != nil)
            #expect(provider?.allowsEndpointConfiguration == true)
            #expect(provider?.allowsMaxOutputTokens == true)
            #expect(provider?.fetchesModelList == true)
            #expect(provider?.allowsNameConfiguration == false)
            #expect(provider?.supportsReasoning == false)
            #expect(provider?.supportsImages == false)
        }
    }

    @Test("Local providers build the OpenAI-compatible transport, not a bespoke one")
    func makeProviderUsesOpenAICompatible() {
        for type in [AIProviderType.llamaCpp, .mlx] {
            let config = AIProviderConfig(type: type, model: "local-model")
            #expect(descriptor(for: type)?.makeProvider(config, nil) is OpenAICompatibleProvider)
        }
    }

    @Test("The default local endpoint resolves to the OpenAI chat-completions path")
    func defaultEndpointResolvesToOpenAIPath() {
        for type in [AIProviderType.llamaCpp, .mlx] {
            let config = AIProviderConfig(type: type)
            #expect(config.endpoint == "http://localhost:8080")
            #expect(config.endpoint.openAIPath("chat/completions") == "http://localhost:8080/v1/chat/completions")
        }
    }
}
