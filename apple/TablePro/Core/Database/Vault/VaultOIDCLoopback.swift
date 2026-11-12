//
//  VaultOIDCLoopback.swift
//  TablePro
//

import Foundation
import TableProHTTP

protocol VaultOIDCCallbackReceiving: Sendable {
    func start() async throws
    func callback(timeout: Duration) async throws -> [String: String]
    func stop()
}

// Listens where the vault CLI does, http://localhost:8250/oidc/callback, the redirect URI an OIDC role already allows.
final class VaultOIDCLoopback: VaultOIDCCallbackReceiving, Sendable {
    static let port: UInt16 = 8_250
    static let callbackPath = "/oidc/callback"

    private let listener: LoopbackRedirectListener<[String: String]>

    // Only a callback carrying the `state` from Vault's sign-in page ends the wait.
    init(expectedState: String, port: UInt16 = VaultOIDCLoopback.port, headTimeout: TimeInterval = 5) {
        listener = LoopbackRedirectListener(port: port, headTimeout: headTimeout) { head in
            guard let parameters = Self.callbackParameters(in: head, expectedState: expectedState) else {
                return .ignore(LoopbackRedirectPage.badRequest)
            }
            return .settle(Self.successPage(), .success(parameters))
        }
    }

    func start() async throws {
        try await startListening()
    }

    @discardableResult
    func startListening() async throws -> UInt16 {
        do {
            return try await listener.start()
        } catch is LoopbackRedirectListenerError {
            throw VaultError.oidcCallbackPortInUse
        }
    }

    func callback(timeout: Duration) async throws -> [String: String] {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await listener.outcome(
            timeout: seconds,
            timeoutError: VaultError.oidcFailed(String(localized: "The browser sign-in timed out."))
        )
    }

    func stop() {
        listener.stop()
    }

    static func callbackParameters(in head: Data, expectedState: String) -> [String: String]? {
        guard !expectedState.isEmpty,
              LoopbackRedirectRequest.isComplete(head),
              let target = LoopbackRedirectRequest.getTarget(LoopbackRedirectRequest.text(of: head)),
              let components = URLComponents(string: target),
              components.host == nil,
              components.path == callbackPath
        else { return nil }
        let items = LoopbackRedirectRequest.formDecodedItems(in: components)
        guard let state = LoopbackRedirectRequest.singleValue(named: "state", in: items),
              LoopbackRedirectRequest.constantTimeEquals(state, expectedState)
        else { return nil }
        var parameters: [String: String] = [:]
        for item in items {
            if let value = item.value { parameters[item.name] = value }
        }
        return parameters
    }

    private static func successPage() -> Data {
        LoopbackRedirectPage.response(
            status: "200 OK",
            title: "TablePro",
            message: String(localized: "Signed in to Vault. You can close this window and return to TablePro.")
        )
    }
}
