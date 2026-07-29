//
//  CursorRegistrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Cursor provider registration")
struct CursorRegistrationTests {
    init() {
        AIProviderRegistration.registerAll()
    }

    private func descriptor() -> AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: AIProviderType.cursor.rawValue)
    }

    @Test("Cursor allows an optional API key and is a known type")
    func authStyleAndType() {
        #expect(AIProviderType.cursor.authStyle == .optionalApiKey)
        #expect(AIProviderType.allCases.contains(.cursor))
        #expect(AIProviderType(rawValue: "cursor") == .cursor)
    }

    @Test("Cursor descriptor capabilities")
    func capabilities() {
        let cursor = descriptor()
        #expect(cursor != nil)
        #expect(cursor?.fetchesModelList == true)
        #expect(cursor?.allowsEndpointConfiguration == false)
        #expect(cursor?.allowsMaxOutputTokens == false)
        #expect(cursor?.oauthFlowKind == nil)
        #expect(cursor?.showsTelemetryToggle == false)
    }

    @Test("Cursor offers several curated models, not just one")
    func curatedModels() {
        let ids = descriptor()?.curatedModels.map(\.id) ?? []
        #expect(ids.count > 1)
        #expect(ids.contains("composer-2.5"))
        #expect(ids.contains("auto"))
    }

    @Test("A key selects the REST provider, no key selects the CLI agent provider")
    func makeProviderBranchesOnKey() {
        let config = AIProviderConfig(type: .cursor, model: "composer-2")
        #expect(descriptor()?.makeProvider(config, "sk-cursor-test") is CursorProvider)
        #expect(descriptor()?.makeProvider(config, nil) is CursorAgentProvider)
        #expect(descriptor()?.makeProvider(config, "") is CursorAgentProvider)
    }
}
