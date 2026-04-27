//
//  CopilotAuthManager.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
final class CopilotAuthManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotAuth")

    struct SignInResult {
        let userCode: String
        let verificationURI: String
    }

    private struct SignInInitiateResponse: Decodable {
        let status: String
        let userCode: String
        let verificationUri: String
    }

    private struct SignInConfirmResponse: Decodable {
        let status: String
        let user: String
    }

    func initiateSignIn(transport: LSPTransport) async throws -> SignInResult {
        let data: Data = try await transport.sendRequest(
            method: "signInInitiate",
            params: EmptyLSPParams()
        )
        let response = try JSONDecoder().decode(SignInInitiateResponse.self, from: data)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(response.userCode, forType: .string)

        if let url = URL(string: response.verificationUri) {
            NSWorkspace.shared.open(url)
        }

        Self.logger.info("Sign-in initiated, user code copied to clipboard")
        return SignInResult(userCode: response.userCode, verificationURI: response.verificationUri)
    }

    func completeSignIn(transport: LSPTransport) async throws -> String {
        let maxAttempts = 60
        let pollInterval: Duration = .seconds(2)

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else {
                throw CopilotError.authenticationFailed(String(localized: "Sign-in cancelled"))
            }
            let data: Data = try await transport.sendRequest(
                method: "signInConfirm",
                params: EmptyLSPParams()
            )
            let response = try JSONDecoder().decode(SignInConfirmResponse.self, from: data)

            if response.status == "OK" || response.status == "AlreadySignedIn" {
                Self.logger.info("Sign-in completed for user: \(response.user)")
                return response.user
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch is CancellationError {
                throw CopilotError.authenticationFailed(String(localized: "Sign-in cancelled"))
            }
        }

        throw CopilotError.authenticationFailed(String(localized: "Sign-in timed out"))
    }

    func signOut(transport: LSPTransport) async {
        do {
            let _: Data = try await transport.sendRequest(
                method: "signOut",
                params: EmptyLSPParams()
            )
            Self.logger.info("Signed out of GitHub Copilot")
        } catch {
            Self.logger.error("Sign-out failed: \(error.localizedDescription)")
        }
    }
}
