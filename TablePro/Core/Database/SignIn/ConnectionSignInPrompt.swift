import AppKit
import Foundation

@MainActor
enum ConnectionSignInPrompt {
    /// Asks whether to sign in, and runs it if the user agrees. Returns true only when a sign-in
    /// completed, so the caller decides what follows: the connection form asks the user to test
    /// again, the connect path retries on its own.
    static func offer(
        _ provider: ConnectionSignInProvider,
        fields: [String: String],
        window: NSWindow?
    ) async -> Bool {
        let confirmed = await AlertHelper.confirmCritical(
            title: provider.title,
            message: provider.message(fields),
            confirmButton: String(localized: "Sign In"),
            window: window
        )
        guard confirmed else { return false }

        do {
            try await provider.signIn(fields, window)
            return true
        } catch {
            AlertHelper.showErrorSheet(
                title: provider.failureTitle,
                message: error.localizedDescription,
                window: window
            )
            return false
        }
    }
}
