import AppKit
import Foundation
import TableProPluginKit

enum EntraSignInService {
    /// True when the driver failed only because nobody has signed in yet, or the saved sign-in
    /// can no longer be refreshed. The connection form offers the browser flow on these.
    static func needsSignIn(_ error: Error) -> Bool {
        guard let entraError = error as? EntraOAuthError else { return false }
        return entraError.needsSignIn
    }

    /// Runs the device code flow. The user code is put on the pasteboard and shown, because the
    /// Microsoft endpoint returns a bare verification URL and expects the code to be typed in.
    static func signIn(fields: [String: String], window: NSWindow?) async throws {
        try await EntraCredentialResolver.shared.signIn(
            fields: fields,
            presentCode: { url, userCode in
                Task { @MainActor in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                    NSWorkspace.shared.open(url)
                    AlertHelper.showInfoSheet(
                        title: String(localized: "Finish Signing In"),
                        message: String(
                            format: String(
                                localized: """
                                Enter the code %@ in the browser to finish signing in to \
                                Microsoft Entra ID. The code is on your clipboard.
                                """
                            ),
                            userCode
                        ),
                        window: window
                    )
                }
            }
        )
    }

    static func signOut(fields: [String: String]) async {
        await EntraCredentialResolver.shared.signOut(fields: fields)
    }
}
