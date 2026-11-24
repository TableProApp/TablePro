import CryptoKit
import Foundation
import os
import TableProMCP
import TableProPluginKit

enum MCPConsentOutcome: Sendable, Equatable {
    case nativeAlert
    case preApproved

    var capabilities: CallerCapabilities {
        self == .preApproved ? [.confirmationPreCleared] : []
    }
}

enum MCPToolConsent {
    static let method = "tools/call"

    // Accepted states by the nonce sealed into each, so one runs once. A claim outlives its state's signed expiry.
    private static let spent = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    // `target` is `target(of:)` for the operation the form shows. The arguments alone do not fix it: a name left out
    // resolves to whatever the session browses when the answer comes back.
    static func resolve(
        key: String,
        message: String,
        detail: String?,
        target: String,
        context: MCPRequestContext,
        clock: Date = Date()
    ) throws -> MCPConsentOutcome {
        guard context.clientCapabilities.supportsElicitationMode("form") else {
            return .nativeAlert
        }

        let digest = MCPRequestState.digest(ofParams: context.params)
        let ask = Question(key: key, message: message, detail: detail, target: target, digest: digest)
        guard let presented = MCPInputResponses.requestState(in: context.params) else {
            throw try inputRequired(ask, context: context, now: clock)
        }

        let sealed: JsonValue
        do {
            sealed = try MCPRequestState.open(
                presented,
                principal: context.principal,
                method: method,
                paramsDigest: digest,
                now: clock
            )
        } catch let error as MCPRequestStateError {
            throw MCPProtocolError.invalidParams(detail: error.detail)
        }

        // An answer about another connection, database, schema or statement is not an answer about this one.
        guard sealed["consent"]?.stringValue == key, sealed["target"]?.stringValue == target,
              let nonce = sealed["nonce"]?.stringValue, let expires = sealed["expires"]?.intValue
        else {
            throw try inputRequired(ask, context: context, now: clock)
        }

        guard let response = MCPInputResponses.elicitation(named: key, in: context.params) else {
            throw try inputRequired(ask, context: context, now: clock)
        }

        guard response.isAccepted, response.bool("approved") ?? true else {
            throw MCPToolExecutionError.denied(
                String(localized: "The user did not approve this operation.")
            )
        }
        guard claim(nonce, until: Date(timeIntervalSince1970: Double(expires + 1)), now: clock) else {
            throw MCPProtocolError.invalidParams(
                detail: "This approval was already used. Call again without requestState to ask for a new one."
            )
        }
        return .preApproved
    }

    private static func claim(_ nonce: String, until expiry: Date, now: Date) -> Bool {
        spent.withLock { claims in
            claims = claims.filter { $0.value > now }
            return claims.updateValue(expiry, forKey: nonce) == nil
        }
    }

    // A digest of where and what the operation runs, sealed into the signed state so the client cannot change it.
    static func target(of operation: PendingOperation) -> String {
        let fields: JsonValue = .object([
            "connection": .string(operation.scope.connectionId.uuidString),
            "session": operation.driverGeneration.map { .string($0.uuidString) } ?? .null,
            "database": .string(operation.scope.database),
            "schema": operation.scope.schema.map(JsonValue.string) ?? .null,
            "kind": .string(String(describing: operation.kind)),
            "unit": .string(String(describing: operation.unit)),
            "statements": .array(operation.statements.map { statement in
                .object([
                    "sql": .string(statement.sql),
                    "parameters": .array(statement.parameters.map(encoded))
                ])
            }),
            "shown": .array(operation.displayStatements.map(JsonValue.string))
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(fields) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // One target for several operations shown together, in the order they were shown.
    static func target(covering targets: [String]) -> String {
        SHA256.hash(data: Data(targets.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoded(_ value: PluginCellValue) -> JsonValue {
        switch value {
        case .null: return .null
        case .text(let text): return .object(["text": .string(text)])
        case .bytes(let data): return .object(["bytes": .string(data.base64EncodedString())])
        }
    }

    private struct Question {
        let key: String
        let message: String
        let detail: String?
        let target: String
        let digest: String
    }

    private static func inputRequired(_ ask: Question, context: MCPRequestContext, now: Date) throws -> MCPInputRequired {
        let expiresAt = now.addingTimeInterval(MCPRequestState.defaultLifetime)
        // The expiry the envelope signs, rounded the same way, so a claim lasts as long as the state can open.
        let state = try MCPRequestState.seal(
            .object([
                "consent": .string(ask.key),
                "target": .string(ask.target),
                "nonce": .string(UUID().uuidString),
                "expires": .int(Int(expiresAt.timeIntervalSince1970.rounded()))
            ]),
            principal: context.principal,
            method: method,
            paramsDigest: ask.digest,
            expiresAt: expiresAt
        )
        return MCPInputRequired(
            inputRequests: [MCPElicitationRequest.approval(key: ask.key, message: ask.message, detail: ask.detail)],
            requestState: state
        )
    }
}
