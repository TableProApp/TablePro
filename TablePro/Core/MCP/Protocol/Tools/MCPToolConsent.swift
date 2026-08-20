import Foundation

enum MCPConsentOutcome: Sendable, Equatable {
    case nativeAlert
    case preApproved

    var capabilities: CallerCapabilities {
        self == .preApproved ? [.confirmationPreCleared] : []
    }
}

enum MCPToolConsent {
    static let method = "tools/call"

    static func resolve(
        key: String,
        message: String,
        detail: String?,
        context: MCPRequestContext,
        clock: Date = Date()
    ) throws -> MCPConsentOutcome {
        guard context.clientCapabilities.supportsElicitationMode("form") else {
            return .nativeAlert
        }

        let digest = MCPRequestState.digest(ofParams: context.params)
        guard let presented = MCPInputResponses.requestState(in: context.params) else {
            throw try inputRequired(key: key, message: message, detail: detail, context: context, digest: digest, now: clock)
        }

        do {
            _ = try MCPRequestState.open(
                presented,
                principal: context.principal,
                method: method,
                paramsDigest: digest,
                now: clock
            )
        } catch let error as MCPRequestStateError {
            throw MCPProtocolError.invalidParams(detail: error.detail)
        }

        guard let response = MCPInputResponses.elicitation(named: key, in: context.params) else {
            throw try inputRequired(key: key, message: message, detail: detail, context: context, digest: digest, now: clock)
        }

        guard response.isAccepted, response.bool("approved") ?? true else {
            throw MCPToolExecutionError.denied(
                String(localized: "The user did not approve this operation.")
            )
        }
        return .preApproved
    }

    private static func inputRequired(
        key: String,
        message: String,
        detail: String?,
        context: MCPRequestContext,
        digest: String,
        now: Date
    ) throws -> MCPInputRequired {
        let state = try MCPRequestState.seal(
            .object(["consent": .string(key)]),
            principal: context.principal,
            method: method,
            paramsDigest: digest,
            expiresAt: now.addingTimeInterval(MCPRequestState.defaultLifetime)
        )
        return MCPInputRequired(
            inputRequests: [MCPElicitationRequest.approval(key: key, message: message, detail: detail)],
            requestState: state
        )
    }
}
