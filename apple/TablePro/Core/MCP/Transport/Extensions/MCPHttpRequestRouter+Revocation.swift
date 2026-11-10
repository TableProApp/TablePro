import Foundation
import os
import TableProMCP

internal extension MCPHttpRequestRouter {
    static let maxRevocationTokenBytes = 1_024

    // RFC 7009: holding the token is the credential, and an unknown token answers 200 like a revoked one.
    func handleTokenRevocation(body: Data, context: HttpConnectionContext) async {
        Self.logger.info("Integrations revoke request received (\(body.count, privacy: .public) bytes)")

        guard let token = Self.revocationToken(fromForm: body) else {
            Self.logger.warning("Integrations revoke refused: no single token parameter")
            await respondRevocationError(context: context, error: "invalid_request")
            return
        }

        let outcome = await tokenRevoker.revoke(presentedToken: token)
        switch outcome {
        case .revoked, .alreadyRevoked, .unknown:
            Self.logger.info("Integrations revoke answered: outcome=\(String(describing: outcome), privacy: .public)")
            await context.writePlainJsonResponse(status: .ok, body: Data("{}".utf8))
            await context.completeResponse()
        case .bridgeCredential:
            Self.logger.warning("Integrations revoke refused: the bridge credential is not revocable here")
            await respondRevocationError(context: context, error: "unsupported_token_type")
        case .notPersisted:
            Self.logger.error("Integrations revoke not saved: the token store could not be written")
            // RFC 7009 section 2.2.1: on 503 the client must assume the token still exists.
            await context.writePlainJsonError(status: .serviceUnavailable, message: "temporarily_unavailable")
            await context.completeResponse()
        }
    }

    // RFC 6749 section 3.2: a parameter without a value counts as omitted, a repeated one is invalid_request.
    static func revocationToken(fromForm body: Data) -> String? {
        guard let form = String(data: body, encoding: .utf8) else { return nil }
        var tokens: [String] = []
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = formDecoded(parts[0]) else { return nil }
            guard name == "token" else { continue }
            guard let value = parts.count == 2 ? formDecoded(parts[1]) : "" else { return nil }
            if !value.isEmpty {
                tokens.append(value)
            }
        }
        guard tokens.count == 1, let token = tokens.first, token.utf8.count <= maxRevocationTokenBytes else {
            return nil
        }
        return token
    }

    private static func formDecoded(_ component: Substring) -> String? {
        component.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private func respondRevocationError(context: HttpConnectionContext, error: String) async {
        await context.writePlainJsonError(status: .badRequest, message: error)
        await context.completeResponse()
    }
}
