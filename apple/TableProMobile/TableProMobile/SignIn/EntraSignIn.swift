import Foundation
import TableProPluginKit
import UIKit

// The device code flow needs no redirect URI and no in-app browser, so it works here with the
// system browser and a one-time code.
enum EntraSignIn {
    static func needsSignIn(_ error: Error) -> Bool {
        guard let entraError = error as? EntraOAuthError else { return false }
        return entraError.needsSignIn
    }

    static func method(fields: [String: String]) -> SignInMethod {
        SignInMethod(
            question: ConnectionPrompt(
                title: String(localized: "Microsoft Entra ID Sign-In Required"),
                message: String(localized: "Sign in to Microsoft Entra ID with your browser?"),
                confirmTitle: String(localized: "Sign In")
            ),
            signIn: { prompts, generation in
                try await EntraCredentialResolver.shared.signIn(
                    fields: fields,
                    presentCode: { url, userCode in
                        Task { @MainActor in
                            present(code: userCode, url: url, prompts: prompts, generation: generation)
                        }
                    }
                )
            }
        )
    }

    // Microsoft returns a bare URL and expects the code to be entered there, so it has to be shown
    // as well as copied.
    private static func present(code: String, url: URL, prompts: ConnectionPromptQueue, generation: Int) {
        UIPasteboard.general.string = code
        SignInOffer.showCode(
            String(
                format: String(
                    localized: "Enter the code %@ in the browser to finish signing in. It is on your clipboard."
                ),
                code
            ),
            opening: url,
            prompts: prompts,
            generation: generation
        )
    }
}
