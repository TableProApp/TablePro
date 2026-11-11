//
//  SnowflakeBrowserAuthServer.swift
//  SnowflakeDriverPlugin
//
//  Ephemeral localhost HTTP server that captures the SAML token returned by the
//  identity provider during EXTERNALBROWSER (SSO) authentication.
//

import Foundation
import TableProHTTP
import TableProSnowflakeCore

final class SnowflakeBrowserAuthServer: Sendable {
    private let listener = LoopbackRedirectListener<String>(port: 0) { head in
        switch SnowflakeBrowserCallback.parse(requestHead: head) {
        case .token(let token):
            return .settle(SnowflakeBrowserAuthServer.successPage, .success(token))
        case .ignore:
            return .ignore(LoopbackRedirectPage.badRequest)
        }
    }

    func start(timeout: TimeInterval = 120) async throws -> UInt16 {
        do {
            return try await listener.start(readyTimeout: timeout)
        } catch LoopbackRedirectListenerError.timedOut {
            throw SnowflakeError.timeout("Browser authentication listener timed out")
        } catch is LoopbackRedirectListenerError {
            throw SnowflakeError.authFailed("Browser auth server failed")
        }
    }

    func waitForToken(timeout: TimeInterval = 120) async throws -> String {
        try await listener.outcome(timeout: timeout, timeoutError: SnowflakeError.timeout("Browser authentication timed out"))
    }

    func stop() {
        listener.stop()
    }

    private static let successPage = LoopbackRedirectPage.response(
        status: "200 OK",
        title: "Authentication Successful",
        message: "You can close this tab and return to TablePro."
    )
}
