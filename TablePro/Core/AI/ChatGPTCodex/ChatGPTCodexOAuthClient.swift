//
//  ChatGPTCodexOAuthClient.swift
//  TablePro
//

import Foundation
import os

final class ChatGPTCodexOAuthClient: ChatGPTCodexTokenRefreshing {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatGPTCodexOAuthClient")

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func authorizeURL(pkce: ChatGPTCodexPKCE) -> URL? {
        var components = URLComponents(string: ChatGPTCodex.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: ChatGPTCodex.clientID),
            URLQueryItem(name: "redirect_uri", value: ChatGPTCodex.redirectURI),
            URLQueryItem(name: "scope", value: ChatGPTCodex.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "originator", value: ChatGPTCodex.originator),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return components?.url
    }

    func exchangeCode(code: String, verifier: String) async throws -> ChatGPTCodexTokenResponse {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": ChatGPTCodex.redirectURI,
            "client_id": ChatGPTCodex.clientID,
            "code_verifier": verifier
        ]
        return try await postToken(form: form, fallbackRefreshToken: "")
    }

    func refresh(refreshToken: String) async throws -> ChatGPTCodexTokenResponse {
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ChatGPTCodex.clientID,
            "scope": ChatGPTCodex.scope
        ]
        return try await postToken(form: form, fallbackRefreshToken: refreshToken)
    }

    func revoke(refreshToken: String) async {
        guard !refreshToken.isEmpty, let url = URL(string: ChatGPTCodex.revokeEndpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "token": refreshToken,
            "client_id": ChatGPTCodex.clientID
        ])
        _ = try? await session.data(for: request)
    }

    private func postToken(
        form: [String: String],
        fallbackRefreshToken: String
    ) async throws -> ChatGPTCodexTokenResponse {
        guard let url = URL(string: ChatGPTCodex.tokenEndpoint) else {
            throw AIProviderError.invalidEndpoint(ChatGPTCodex.tokenEndpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("ChatGPT token request failed: \(error.localizedDescription, privacy: .public)")
            throw AIProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.mapHTTPError(
                statusCode: httpResponse.statusCode,
                body: body,
                treatForbiddenAsAuthFailure: true
            )
        }
        return try Self.parseTokenResponse(data, fallbackRefreshToken: fallbackRefreshToken)
    }

    static func parseTokenResponse(
        _ data: Data,
        fallbackRefreshToken: String
    ) throws -> ChatGPTCodexTokenResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw AIProviderError.authenticationFailed(String(localized: "ChatGPT did not return an access token."))
        }
        let idToken = json["id_token"] as? String ?? ""
        let refreshToken = json["refresh_token"] as? String ?? fallbackRefreshToken
        let expiresAt = resolveExpiry(json: json, accessToken: accessToken)
        return ChatGPTCodexTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt
        )
    }

    private static func resolveExpiry(json: [String: Any], accessToken: String) -> Date {
        if let expiresIn = json["expires_in"] as? Double {
            return Date().addingTimeInterval(expiresIn)
        }
        if let expiration = ChatGPTCodexJWT.expiration(from: accessToken) {
            return expiration
        }
        return Date().addingTimeInterval(3_600)
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8) ?? Data()
    }
}
