//
//  EntraSignIn.swift
//  TableProMobile
//
//  Microsoft Entra ID sign-in for SQL Server connections. The device code flow needs no redirect
//  URI and no in-app browser, so it works here with the system browser and a one-time code.
//

import Foundation
import TableProDatabase
import TableProPluginKit
import UIKit

enum EntraSignIn {
    static func needsSignIn(_ error: Error) -> Bool {
        guard let entraError = error as? EntraOAuthError else { return false }
        return entraError.needsSignIn
    }

    /// Offers the sign-in and runs it. Returns true when it completed, so the caller can retry.
    /// The question and the code both belong to the attempt, so they go through its own queue.
    static func offer(fields: [String: String], prompts: ConnectionPromptQueue) async -> Bool {
        let confirmed = await prompts.confirm(
            ConnectionPrompt(
                title: String(localized: "Microsoft Entra ID Sign-In Required"),
                message: String(localized: "Sign in to Microsoft Entra ID with your browser?"),
                confirmTitle: String(localized: "Sign In")
            )
        )
        guard confirmed else { return false }

        do {
            try await EntraCredentialResolver.shared.signIn(
                fields: fields,
                presentCode: { url, userCode in
                    Task { @MainActor in
                        present(code: userCode, url: url, prompts: prompts)
                    }
                }
            )
            return true
        } catch {
            return false
        }
    }

    /// Puts the code on the pasteboard and opens the verification page. Microsoft returns a bare
    /// URL and expects the code to be entered there, so it has to be shown as well as copied.
    @MainActor
    private static func present(code: String, url: URL, prompts: ConnectionPromptQueue) {
        UIPasteboard.general.string = code
        prompts.notify(
            ConnectionPrompt(
                title: String(localized: "Finish Signing In"),
                message: String(
                    format: String(
                        localized: "Enter the code %@ in the browser to finish signing in. It is on your clipboard."
                    ),
                    code
                ),
                confirmTitle: String(localized: "OK"),
                style: .notice
            )
        )
        UIApplication.shared.open(url)
    }
}
