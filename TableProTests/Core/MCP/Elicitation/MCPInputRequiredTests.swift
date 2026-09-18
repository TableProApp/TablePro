//
//  MCPInputRequiredTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPInputRequired result shape")
struct MCPInputRequiredTests {
    private let serverInfo = MCPImplementation(name: "TablePro", version: "1.0")

    private func signal(
        requests: [MCPElicitationRequest] = [
            MCPElicitationRequest.approval(
                key: "approve_statement",
                message: "Allow a destructive statement?",
                detail: "DROP TABLE users"
            )
        ],
        requestState: String? = "sealed-state"
    ) -> MCPInputRequired {
        MCPInputRequired(inputRequests: requests, requestState: requestState)
    }

    @Test("An input-required result carries the requests keyed by their identifier")
    func requestsAreKeyed() {
        let result = signal().asResult
        #expect(result.kind == .inputRequired)
        let requests = result.payload["inputRequests"]?.objectValue
        #expect(requests?.keys.sorted() == ["approve_statement"])
        #expect(
            requests?["approve_statement"]?["method"]?.stringValue == "elicitation/create"
        )
        #expect(result.payload["requestState"]?.stringValue == "sealed-state")
    }

    @Test("An input-required result is never cacheable")
    func inputRequiredIsNeverCacheable() {
        let result = signal().asResult
        #expect(result.cacheHint == nil)

        let encoded = result.asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(encoded["resultType"]?.stringValue == "input_required")
        #expect(encoded["ttlMs"] == nil)
        #expect(encoded["cacheScope"] == nil)
    }

    @Test("A complete result that does carry a hint proves the absence above is deliberate")
    func completeResultsCanCarryHints() {
        let cached = MCPResult
            .complete(["tools": .array([])], cacheHint: .privateFor(seconds: 300))
            .asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(cached["ttlMs"]?.intValue == 300_000)
        #expect(cached["cacheScope"]?.stringValue == "private")

        let uncacheable = MCPResult
            .complete(["tools": .array([])], cacheHint: .uncacheable)
            .asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(uncacheable["ttlMs"]?.intValue == 0)
        #expect(uncacheable["cacheScope"]?.stringValue == "private")
    }

    @Test("A legacy client never sees the modern result envelope")
    func legacyEraOmitsTheModernEnvelope() {
        let encoded = signal().asResult.asJsonValue(era: .legacy, serverInfo: serverInfo)
        #expect(encoded["resultType"] == nil)
        #expect(encoded["ttlMs"] == nil)
        #expect(encoded["cacheScope"] == nil)
    }

    @Test("A signal must carry at least one of inputRequests or requestState")
    func atLeastOneFieldIsRequired() {
        #expect(signal().isValid)
        #expect(signal(requests: [], requestState: "sealed-state").isValid)
        #expect(signal(requestState: nil).isValid)
        #expect(!MCPInputRequired(inputRequests: [], requestState: nil).isValid)
    }

    @Test("An approval request asks for one boolean the client can render")
    func approvalRequestShape() {
        let request = MCPElicitationRequest.approval(
            key: "approve_statement",
            message: "Allow?",
            detail: "DROP TABLE users"
        )
        let schema = request.asJsonValue["params"]?["requestedSchema"]
        #expect(schema?["type"]?.stringValue == "object")
        #expect(schema?["properties"]?["approved"]?["type"]?.stringValue == "boolean")
        #expect(schema?["required"]?.arrayValue?.compactMap(\.stringValue) == ["approved"])
        #expect(
            schema?["properties"]?["approved"]?["description"]?.stringValue == "DROP TABLE users"
        )
    }
}

@Suite("MCPInputResponses parsing")
struct MCPInputResponsesTests {
    @Test("An empty requestState is treated as absent")
    func emptyRequestStateIsAbsent() {
        #expect(MCPInputResponses.requestState(in: .object(["requestState": .string("")])) == nil)
        #expect(MCPInputResponses.requestState(in: .object(["requestState": .null])) == nil)
        #expect(MCPInputResponses.requestState(in: nil) == nil)
        #expect(MCPInputResponses.requestState(in: .object(["requestState": .string("s")])) == "s")
    }

    @Test("A response is parsed only when its action is one the protocol defines")
    func onlyKnownActionsParse() {
        let accepted = MCPInputResponses.elicitation(
            named: "k",
            in: .object([
                "inputResponses": .object([
                    "k": .object(["action": .string("accept"), "content": .object(["approved": .bool(true)])])
                ])
            ])
        )
        #expect(accepted?.isAccepted == true)
        #expect(accepted?.bool("approved") == true)

        let unknown = MCPInputResponses.elicitation(
            named: "k",
            in: .object(["inputResponses": .object(["k": .object(["action": .string("maybe")])])])
        )
        #expect(unknown == nil)

        let declined = MCPInputResponses.elicitation(
            named: "k",
            in: .object(["inputResponses": .object(["k": .object(["action": .string("decline")])])])
        )
        #expect(declined?.isAccepted == false)
    }

    @Test("A response for another key is never read as this key's answer")
    func responsesAreKeyed() {
        let params = JsonValue.object([
            "inputResponses": .object([
                "other": .object(["action": .string("accept")])
            ])
        ])
        #expect(MCPInputResponses.elicitation(named: "approve_statement", in: params) == nil)
    }
}
