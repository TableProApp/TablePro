//
//  XAIOAuthClientTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("XAIOAuthClient")
struct XAIOAuthClientTests {
    private func queryItems(_ url: URL?) -> [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }

    @Test("The authorize URL carries the verified PKCE and client parameters")
    func authorizeURLParameters() {
        let client = XAIOAuthClient()
        let pkce = XAIPKCE()
        let redirect = "http://127.0.0.1:56121/callback"
        let url = client.authorizeURL(pkce: pkce, redirectURI: redirect)

        #expect(url?.absoluteString.hasPrefix("https://auth.x.ai/oauth2/authorize") == true)
        let items = queryItems(url)
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828")
        #expect(items["redirect_uri"] == redirect)
        #expect(items["scope"] == "openid profile email offline_access grok-cli:access api:access")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == pkce.state)
    }

    @Test("A token response parses access, refresh, and id tokens with a server expiry")
    func parseTokenResponse() throws {
        let json = """
        {"access_token":"a","refresh_token":"r","id_token":"i","expires_in":600,"token_type":"Bearer"}
        """
        let response = try XAIOAuthClient.parseTokenResponse(Data(json.utf8), fallbackRefreshToken: "old")
        #expect(response.accessToken == "a")
        #expect(response.refreshToken == "r")
        #expect(response.idToken == "i")
        #expect(response.expiresAt > Date())
    }

    @Test("A refresh response without a rotated token keeps the previous refresh token")
    func parseTokenResponseKeepsFallbackRefresh() throws {
        let json = #"{"access_token":"a2","expires_in":600}"#
        let response = try XAIOAuthClient.parseTokenResponse(Data(json.utf8), fallbackRefreshToken: "keep")
        #expect(response.refreshToken == "keep")
    }

    @Test("A response without an access token is an authentication failure")
    func parseTokenResponseMissingAccessToken() {
        let json = #"{"refresh_token":"r"}"#
        #expect(throws: AIProviderError.self) {
            _ = try XAIOAuthClient.parseTokenResponse(Data(json.utf8), fallbackRefreshToken: "")
        }
    }
}
