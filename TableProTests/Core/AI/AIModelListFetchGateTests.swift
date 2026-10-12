//
//  AIModelListFetchGateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct AIModelListFetchGateTests {
    @Test("A provider that cannot fetch a model list is blocked whatever the key")
    func blocksWhenNotFetchable() {
        for style in [AIProviderType.AuthStyle.apiKey, .optionalApiKey, .oauth, .none] {
            #expect(
                AIModelListFetchGate.blocker(
                    fetchesModelList: false, takesEndpoint: false, endpoint: "https://h/v1",
                    authStyle: style, apiKey: "sk-live"
                )
                    == .notFetchable
            )
        }
    }

    @Test("A required key that is missing blocks the fetch")
    func blocksOnMissingRequiredKey() {
        for key in ["", "   ", "\n\t"] {
            #expect(
                AIModelListFetchGate.blocker(
                    fetchesModelList: true, takesEndpoint: true, endpoint: "https://h/v1",
                    authStyle: .apiKey, apiKey: key
                )
                    == .missingAPIKey
            )
        }
    }

    @Test("A required key that is present lets the fetch run")
    func allowsWithRequiredKey() {
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true, takesEndpoint: true, endpoint: "https://h/v1",
                authStyle: .apiKey, apiKey: "sk-live"
            ) == nil
        )
    }

    /// Cursor, xAI, OpenCode Zen and now Custom reach a server that may not want a key at all.
    @Test("A provider whose key is optional never blocks on an empty key")
    func allowsOptionalKeyProviders() {
        for style in [AIProviderType.AuthStyle.optionalApiKey, .none, .oauth] {
            #expect(
                AIModelListFetchGate.blocker(
                    fetchesModelList: true, takesEndpoint: true, endpoint: "https://h/v1",
                    authStyle: style, apiKey: ""
                ) == nil
            )
        }
    }

    /// A Custom provider is created with no Base URL, and its key is optional, so nothing else
    /// would stop the sheet asking a transport with no URL for a model list the moment it opens.
    @Test("A provider that takes an endpoint blocks until one is typed")
    func blocksOnMissingEndpoint() {
        for endpoint in ["", "   "] {
            #expect(
                AIModelListFetchGate.blocker(
                    fetchesModelList: true, takesEndpoint: true, endpoint: endpoint,
                    authStyle: .optionalApiKey, apiKey: ""
                ) == .missingEndpoint
            )
        }
    }

    @Test("A provider that reaches a fixed host never blocks on the endpoint")
    func ignoresEndpointWhenNotConfigurable() {
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true, takesEndpoint: false, endpoint: "",
                authStyle: .oauth, apiKey: ""
            ) == nil
        )
    }

    @Test("A missing endpoint is reported before a missing key")
    func endpointOutranksTheKey() {
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true, takesEndpoint: true, endpoint: "",
                authStyle: .apiKey, apiKey: ""
            ) == .missingEndpoint
        )
    }

    @Test("Custom does not block on an empty key")
    func customIsNotBlocked() {
        #expect(
            AIModelListFetchGate.blocker(
                fetchesModelList: true,
                takesEndpoint: true,
                endpoint: "https://api.z.ai/api/paas/v4",
                authStyle: AIProviderType.custom.authStyle,
                apiKey: ""
            ) == nil
        )
    }
}
