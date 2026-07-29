//
//  XAIOAuthClient.swift
//  TablePro
//

import Foundation
import os

final class XAIOAuthClient: XAITokenRefreshing {
    private static let logger = Logger(subsystem: "com.TablePro", category: "XAIOAuthClient")

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func authorizeURL(pkce: XAIPKCE, redirectURI: String) -> URL? {
        var components = URLComponents(string: XAI.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: XAI.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: XAI.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return components?.url
    }

    func exchangeCode(code: String, verifier: String, redirectURI: String) async throws -> XAITokenResponse {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": XAI.clientID,
            "code_verifier": verifier
        ]
        return try await postToken(form: form, fallbackRefreshToken: "")
    }

    func refresh(refreshToken: String) async throws -> XAITokenResponse {
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": XAI.clientID
        ]
        return try await postToken(form: form, fallbackRefreshToken: refreshToken)
    }

    func revoke(refreshToken: String) async {
        guard !refreshToken.isEmpty, let url = URL(string: XAI.revokeEndpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "token": refreshToken,
            "client_id": XAI.clientID
        ])
        _ = try? await session.data(for: request)
    }

    private func postToken(
        form: [String: String],
        fallbackRefreshToken: String
    ) async throws -> XAITokenResponse {
        guard let url = URL(string: XAI.tokenEndpoint) else {
            throw AIProviderError.invalidEndpoint(XAI.tokenEndpoint)
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
            Self.logger.warning("xAI token request failed: \(error.localizedDescription, privacy: .public)")
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
    ) throws -> XAITokenResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw AIProviderError.authenticationFailed(String(localized: "xAI did not return an access token."))
        }
        let idToken = json["id_token"] as? String ?? ""
        let refreshToken = json["refresh_token"] as? String ?? fallbackRefreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3_600
        return XAITokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8) ?? Data()
    }
}
