import Foundation
import os

struct IntegrationsExchangeHandler: MCPRouteHandler {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IntegrationsExchangeHandler")

    private let exchange: @Sendable (PairingExchange) async throws -> String

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var methods: [HTTPRequest.Method] { [.post] }
    var path: String { "/v1/integrations/exchange" }

    init(exchange: @escaping @Sendable (PairingExchange) async throws -> String) {
        self.exchange = exchange
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    static func live() -> IntegrationsExchangeHandler {
        IntegrationsExchangeHandler { request in
            try await MainActor.run {
                try MCPPairingService.shared.exchange(request)
            }
        }
    }

    func handle(_ request: HTTPRequest) async -> MCPRouter.RouteResult {
        guard let body = request.body else {
            return .httpError(status: 400, message: "Missing request body")
        }

        let parsed: ExchangeRequestBody
        do {
            parsed = try decoder.decode(ExchangeRequestBody.self, from: body)
        } catch {
            return .httpError(status: 400, message: "Invalid JSON body")
        }

        guard !parsed.code.isEmpty, !parsed.codeVerifier.isEmpty else {
            return .httpError(status: 400, message: "Missing code or code_verifier")
        }

        let token: String
        do {
            token = try await exchange(
                PairingExchange(code: parsed.code, verifier: parsed.codeVerifier)
            )
        } catch let mcpError as MCPError {
            return Self.mapExchangeError(mcpError)
        } catch {
            Self.logger.error("Pairing exchange failed: \(error.localizedDescription)")
            return .httpError(status: 500, message: "Internal error")
        }

        do {
            let data = try encoder.encode(ExchangeResponseBody(token: token))
            return .json(data, sessionId: nil)
        } catch {
            Self.logger.error("Failed to encode exchange response: \(error.localizedDescription)")
            return .httpError(status: 500, message: "Internal error")
        }
    }

    private static func mapExchangeError(_ error: MCPError) -> MCPRouter.RouteResult {
        switch error {
        case .notFound:
            return .httpError(status: 404, message: "Pairing code not found")
        case .expired:
            return .httpError(status: 410, message: "Pairing code expired")
        case .forbidden:
            return .httpError(status: 403, message: "Challenge mismatch")
        default:
            return .httpError(status: 500, message: "Internal error")
        }
    }

    private struct ExchangeRequestBody: Decodable {
        let code: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
        }
    }

    private struct ExchangeResponseBody: Encodable {
        let token: String
    }
}
