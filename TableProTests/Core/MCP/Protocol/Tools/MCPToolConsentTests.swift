//
//  MCPToolConsentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPToolConsent elicitation round trip")
struct MCPToolConsentTests {
    private static let key = "approve_statement"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let arguments = JsonValue.object([
        "connection_id": .string("6C7B6C2E-0000-4000-8000-000000000001"),
        "query": .string("DROP TABLE users")
    ])

    private func params(
        requestState: String? = nil,
        response: JsonValue? = nil,
        arguments overriddenArguments: JsonValue? = nil
    ) -> JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string("confirm_destructive_operation"),
            "arguments": overriddenArguments ?? arguments
        ]
        if let requestState {
            fields["requestState"] = .string(requestState)
        }
        if let response {
            fields["inputResponses"] = .object([Self.key: response])
        }
        return .object(fields)
    }

    private func context(
        params: JsonValue,
        capabilities: MCPClientCapabilities,
        principal: MCPPrincipal? = nil
    ) -> MCPRequestContext {
        MCPToolTestHarness.context(
            params: params,
            principal: principal,
            clientCapabilities: capabilities
        )
    }

    private func resolve(
        params: JsonValue,
        capabilities: MCPClientCapabilities,
        principal: MCPPrincipal? = nil
    ) throws -> MCPConsentOutcome {
        try MCPToolConsent.resolve(
            key: Self.key,
            message: "Allow a destructive statement on 'Primary'?",
            detail: "DROP TABLE users",
            context: context(params: params, capabilities: capabilities, principal: principal),
            clock: Self.now
        )
    }

    @Test("A client that never declared elicitation is never sent one")
    func clientWithoutElicitationGetsTheNativeAlert() throws {
        let outcome = try resolve(params: params(), capabilities: .none)
        #expect(outcome == .nativeAlert)
        #expect(outcome.capabilities.isEmpty)
    }

    @Test("A client that declares elicitation without the form mode is never sent a form")
    func clientWithoutFormModeGetsTheNativeAlert() throws {
        let outcome = try resolve(
            params: params(),
            capabilities: MCPToolTestHarness.elicitingClient(modes: ["url"])
        )
        #expect(outcome == .nativeAlert)
    }

    @Test("A form-capable client is asked once, with a sealed state to echo back")
    func formCapableClientIsAsked() throws {
        do {
            _ = try resolve(params: params(), capabilities: MCPToolTestHarness.elicitingClient())
            Issue.record("Expected an input-required signal")
        } catch let signal as MCPInputRequired {
            #expect(signal.isValid)
            #expect(signal.requestState?.isEmpty == false)
            #expect(signal.inputRequests.count == 1)
            let request = try #require(signal.inputRequests.first)
            #expect(request.key == Self.key)
            let json = request.asJsonValue
            #expect(json["method"]?.stringValue == "elicitation/create")
            #expect(json["params"]?["mode"]?.stringValue == "form")
            #expect(json["params"]?["requestedSchema"]?["type"]?.stringValue == "object")
            #expect(json["params"]?["requestedSchema"]?["properties"]?["approved"] != nil)
        }
    }

    @Test("Echoing the state back with an approval pre-clears the confirmation")
    func approvalPreClearsTheConfirmation() throws {
        let state = try requestState()
        let outcome = try resolve(
            params: params(
                requestState: state,
                response: .object([
                    "action": .string("accept"),
                    "content": .object(["approved": .bool(true)])
                ])
            ),
            capabilities: MCPToolTestHarness.elicitingClient()
        )
        #expect(outcome == .preApproved)
        #expect(outcome.capabilities.contains(.confirmationPreCleared))
    }

    @Test("A declined or unapproved response denies the operation")
    func declinedResponseDenies() throws {
        let state = try requestState()
        for response in [
            JsonValue.object(["action": .string("decline"), "content": .object([:])]),
            JsonValue.object(["action": .string("cancel"), "content": .object([:])]),
            JsonValue.object([
                "action": .string("accept"),
                "content": .object(["approved": .bool(false)])
            ])
        ] {
            do {
                _ = try resolve(
                    params: params(requestState: state, response: response),
                    capabilities: MCPToolTestHarness.elicitingClient()
                )
                Issue.record("Expected the operation to be denied")
            } catch let error as MCPToolExecutionError {
                #expect(error.code == .denied)
            }
        }
    }

    @Test("A tampered state is rejected as invalid params, never trusted")
    func tamperedStateIsRejected() throws {
        let state = try requestState()
        let forged = String(state.reversed())
        do {
            _ = try resolve(
                params: params(
                    requestState: forged,
                    response: .object([
                        "action": .string("accept"),
                        "content": .object(["approved": .bool(true)])
                    ])
                ),
                capabilities: MCPToolTestHarness.elicitingClient()
            )
            Issue.record("Expected the forged state to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("A state issued to another principal is rejected")
    func stateFromAnotherPrincipalIsRejected() throws {
        let state = try requestState()
        do {
            _ = try resolve(
                params: params(
                    requestState: state,
                    response: .object([
                        "action": .string("accept"),
                        "content": .object(["approved": .bool(true)])
                    ])
                ),
                capabilities: MCPToolTestHarness.elicitingClient(),
                principal: MCPToolTestHarness.principal(fingerprint: "another-token")
            )
            Issue.record("Expected the borrowed state to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("A state cannot be replayed against different arguments")
    func stateCannotBeReplayedOnOtherArguments() throws {
        let state = try requestState()
        do {
            _ = try resolve(
                params: params(
                    requestState: state,
                    response: .object([
                        "action": .string("accept"),
                        "content": .object(["approved": .bool(true)])
                    ]),
                    arguments: .object([
                        "connection_id": .string("6C7B6C2E-0000-4000-8000-000000000001"),
                        "query": .string("DROP TABLE payments")
                    ])
                ),
                capabilities: MCPToolTestHarness.elicitingClient()
            )
            Issue.record("Expected the replayed state to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("A valid state with no answer asks again instead of failing")
    func missingAnswerAsksAgain() throws {
        let state = try requestState()
        do {
            _ = try resolve(
                params: params(requestState: state),
                capabilities: MCPToolTestHarness.elicitingClient()
            )
            Issue.record("Expected a second input-required signal")
        } catch let signal as MCPInputRequired {
            #expect(signal.inputRequests.count == 1)
            #expect(signal.requestState?.isEmpty == false)
        }
    }

    private func requestState() throws -> String {
        do {
            _ = try resolve(params: params(), capabilities: MCPToolTestHarness.elicitingClient())
        } catch let signal as MCPInputRequired {
            return try #require(signal.requestState)
        }
        Issue.record("Expected the first call to ask for input")
        return ""
    }
}
