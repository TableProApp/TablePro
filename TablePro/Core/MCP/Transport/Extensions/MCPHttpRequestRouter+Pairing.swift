import Foundation
import os

internal extension MCPHttpRequestRouter {
    func handlePairingExchange(body: Data, context: HttpConnectionContext) async {
        struct ExchangeBody: Decodable {
            let code: String
            let codeVerifier: String
            enum CodingKeys: String, CodingKey {
                case code
                case codeVerifier = "code_verifier"
            }
        }
        struct ExchangeResponse: Encodable {
            let token: String
        }

        let clientAddress = await context.clientAddress()
        let ip = clientAddress.displayValue
        Self.logger.info("Integrations exchange request received (\(body.count, privacy: .public) bytes)")

        let parsed: ExchangeBody
        do {
            parsed = try JSONDecoder().decode(ExchangeBody.self, from: body)
        } catch {
            Self.logger.warning("Integrations exchange decode failed: \(error.localizedDescription, privacy: .public)")
            MCPAuditLogger.logPairingExchange(outcome: .denied, ip: ip, details: "invalid JSON body")
            await respondPairingFailure(context: context, status: .badRequest, message: "Invalid JSON body")
            return
        }

        guard !parsed.code.isEmpty, !parsed.codeVerifier.isEmpty else {
            Self.logger.warning("Integrations exchange missing code or verifier")
            MCPAuditLogger.logPairingExchange(outcome: .denied, ip: ip, details: "missing code or code_verifier")
            await respondPairingFailure(
                context: context,
                status: .badRequest,
                message: "Missing code or code_verifier"
            )
            return
        }

        guard parsed.code.utf8.count <= 1_024, parsed.codeVerifier.utf8.count <= 1_024 else {
            Self.logger.warning("Integrations exchange field exceeds size cap")
            MCPAuditLogger.logPairingExchange(outcome: .denied, ip: ip, details: "field exceeds 1_024 bytes")
            await respondPairingFailure(context: context, status: .badRequest, message: "Field exceeds size limit")
            return
        }

        do {
            let token = try await MCPPairingService.shared.exchange(
                PairingExchange(code: parsed.code, verifier: parsed.codeVerifier),
                clientAddress: clientAddress
            )
            let payload = try JSONEncoder().encode(ExchangeResponse(token: token))
            await context.writePlainJsonResponse(status: .ok, body: payload)
            await context.completeResponse()
        } catch {
            let mapped = Self.mapExchangeError(error)
            Self.logger.warning(
                "Integrations exchange failed: status=\(mapped.status.code, privacy: .public) reason=\(mapped.message, privacy: .public)"
            )
            await respondPairingFailure(
                context: context,
                status: mapped.status,
                message: mapped.message,
                extraHeaders: mapped.headers
            )
        }
    }

    private func respondPairingFailure(
        context: HttpConnectionContext,
        status: HttpStatus,
        message: String,
        extraHeaders: [(String, String)] = []
    ) async {
        await context.writePlainJsonError(status: status, message: message, extraHeaders: extraHeaders)
        await context.completeResponse()
    }

    static func mapExchangeError(_ error: Error) -> (status: HttpStatus, message: String, headers: [(String, String)]) {
        if let protocolError = error as? MCPProtocolError {
            return (protocolError.httpStatus, protocolError.message, protocolError.extraHeaders)
        }
        guard let domainError = error as? DatabaseAccessError else {
            return (.internalServerError, "Internal error", [])
        }
        switch domainError {
        case .notFound:
            return (.notFound, "Pairing code not found", [])
        case .expired:
            return (.gone, "Pairing code expired", [])
        case .forbidden:
            return (.forbidden, "Challenge mismatch", [])
        case .invalidArgument(let detail):
            return (.badRequest, detail, [])
        default:
            return (.internalServerError, "Internal error", [])
        }
    }
}
