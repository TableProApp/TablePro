//
//  OAuthTokenClient.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

internal struct OAuthTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
}

internal enum AccountError: Error, Equatable {
    case signedOut
    case canceled
    case network(String)
    case oauth(String, description: String?)
    case server(status: Int, code: String?)
    case invalidResponse
    case stateMismatch
    case entitlementRejected(EntitlementVerifier.Failure)
}

internal struct AuthorizationRequest: Equatable, Sendable {
    let url: URL
    let state: String
    let verifier: String

    static func make(configuration: AccountConfiguration, machine: MachineDescription) -> AuthorizationRequest {
        let verifier = randomToken(byteCount: 32)
        let state = randomToken(byteCount: 16)
        let challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = OAuthTokenClient.formBody([
            "response_type": "code",
            "client_id": AccountConfiguration.clientID,
            "redirect_uri": AccountConfiguration.redirectURI,
            "scope": AccountConfiguration.scope,
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "machine_name": machine.name,
            "app_version": machine.appVersion,
            "os_version": machine.osVersion
        ])
        let url = components?.url ?? configuration.authorizationEndpoint
        return AuthorizationRequest(url: url, state: state, verifier: verifier)
    }

    func code(from callback: URL) throws(AccountError) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else { throw .stateMismatch }
        if let error = value("error") {
            throw .oauth(error, description: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else { throw .invalidResponse }
        return code
    }

    private static func randomToken(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}

internal typealias AccountHTTPSend = @Sendable (URLRequest) async throws -> (Data, URLResponse)

internal struct OAuthTokenClient: Sendable {
    static let licenseKeyTokenType = "https://account.tablepro.app/token-types/license-key"
    static let tokenExchangeGrant = "urn:ietf:params:oauth:grant-type:token-exchange"

    private static let logger = Logger(subsystem: "com.TablePro", category: "OAuthTokenClient")

    let configuration: AccountConfiguration
    let send: AccountHTTPSend

    func exchangeCode(_ code: String, verifier: String) async throws(AccountError) -> OAuthTokens {
        try await postToken([
            "grant_type": "authorization_code",
            "client_id": AccountConfiguration.clientID,
            "code": code,
            "redirect_uri": AccountConfiguration.redirectURI,
            "code_verifier": verifier
        ])
    }

    func refresh(_ refreshToken: String) async throws(AccountError) -> OAuthTokens {
        try await postToken([
            "grant_type": "refresh_token",
            "client_id": AccountConfiguration.clientID,
            "refresh_token": refreshToken
        ])
    }

    func exchangeLicenseKey(_ key: String, machine: MachineDescription) async throws(AccountError) -> OAuthTokens {
        try await postToken([
            "grant_type": Self.tokenExchangeGrant,
            "client_id": AccountConfiguration.clientID,
            "subject_token": key,
            "subject_token_type": Self.licenseKeyTokenType,
            "scope": AccountConfiguration.scope,
            "machine_id": machine.machineID,
            "machine_name": machine.name,
            "platform": "macos",
            "app_version": machine.appVersion,
            "os_version": machine.osVersion
        ])
    }

    func revoke(_ refreshToken: String) async throws(AccountError) {
        let (_, response) = try await post(configuration.revocationEndpoint, form: [
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": AccountConfiguration.clientID
        ])
        guard response.statusCode == 200 else {
            throw .server(status: response.statusCode, code: nil)
        }
    }

    private func postToken(_ form: [String: String]) async throws(AccountError) -> OAuthTokens {
        let (data, response) = try await post(configuration.tokenEndpoint, form: form)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            if let error = body["error"] as? String {
                throw .oauth(error, description: body["error_description"] as? String)
            }
            throw .server(status: response.statusCode, code: nil)
        }
        guard let access = body["access_token"] as? String, !access.isEmpty else {
            throw .invalidResponse
        }
        let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue ?? 0
        return OAuthTokens(accessToken: access, refreshToken: body["refresh_token"] as? String, expiresIn: expiresIn)
    }

    private func post(_ url: URL, form: [String: String]) async throws(AccountError) -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formBody(form).utf8)
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw AccountError.invalidResponse }
            return (data, http)
        } catch let error as AccountError {
            throw error
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw .canceled
            }
            Self.logger.warning("OAuth request failed: \(error.publicLogShape, privacy: .public)")
            throw .network(error.localizedDescription)
        }
    }

    // RFC 3986 unreserved only, so a "+" or a non-ASCII machine name survives form decoding.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func formBody(_ form: [String: String]) -> String {
        let allowed = unreserved
        return form.keys.sorted().map { key in
            let value = form[key] ?? ""
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }
}
