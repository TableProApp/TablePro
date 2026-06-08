//
//  OAuthProviderServiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OAuth provider abstraction")
@MainActor
struct OAuthProviderServiceTests {
    @Test("Registry dispatches OAuth providers to a service and others to nil")
    func registryDispatch() {
        #expect(OAuthProviderRegistry.service(for: .copilot) != nil)
        #expect(OAuthProviderRegistry.service(for: .chatgptCodex) != nil)
        #expect(OAuthProviderRegistry.service(for: .claude) == nil)
        #expect(OAuthProviderRegistry.service(for: .openAI) == nil)
        #expect(OAuthProviderRegistry.service(for: .ollama) == nil)
    }

    @Test("Each OAuth provider declares its sign-in flow kind")
    func oauthFlowKinds() {
        AIProviderRegistration.registerAll()
        let registry = AIProviderRegistry.shared
        #expect(registry.descriptor(for: AIProviderType.copilot.rawValue)?.oauthFlowKind == .deviceCode)
        #expect(registry.descriptor(for: AIProviderType.chatgptCodex.rawValue)?.oauthFlowKind == .browserRedirect)
        #expect(registry.descriptor(for: AIProviderType.claude.rawValue)?.oauthFlowKind == nil)
    }

    @Test("OAuthAuthState identity readout")
    func authStateIdentity() {
        #expect(OAuthAuthState.signedIn(identity: "dev@example.com").isSignedIn)
        #expect(!OAuthAuthState.signingIn.isSignedIn)
        #expect(!OAuthAuthState.signedOut.isSignedIn)
    }
}
