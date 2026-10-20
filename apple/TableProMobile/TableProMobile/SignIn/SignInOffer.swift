import Foundation
import TableProDatabase
import TableProModels
import UIKit

struct SignInMethod {
    let question: ConnectionPrompt
    let signIn: @MainActor (_ prompts: ConnectionPromptQueue, _ generation: Int) async throws -> Void
}

enum SignInOutcome {
    case signedIn
    case declined
    case failed(Error)
}

// A connect that failed only because a browser sign-in expired. The question and the code both
// belong to the attempt, so they go through its own queue.
enum SignInOffer {
    static func method(
        for error: Error,
        connection: DatabaseConnection,
        secureStore: any SecureStore
    ) -> SignInMethod? {
        if EntraSignIn.needsSignIn(error) {
            return EntraSignIn.method(fields: connection.additionalFields)
        }
        if AWSSSOSignIn.needsSignIn(error),
           let setup = AWSSSOSignIn.setup(for: connection.id, secureStore: secureStore) {
            return AWSSSOSignIn.method(setup)
        }
        return nil
    }

    // A failed sign-in is the error to show: the connect error only says a sign-in is needed.
    static func offer(_ method: SignInMethod, prompts: ConnectionPromptQueue) async -> SignInOutcome {
        let generation = prompts.generation
        guard await prompts.ask(method.question) else { return .declined }
        do {
            try await method.signIn(prompts, generation)
            return .signedIn
        } catch {
            return .failed(error)
        }
    }

    static func showCode(_ message: String, opening url: URL, prompts: ConnectionPromptQueue, generation: Int) {
        prompts.notify(
            ConnectionPrompt(
                title: String(localized: "Finish Signing In"),
                message: message,
                confirmTitle: String(localized: "OK"),
                style: .notice
            ),
            generation: generation
        )
        UIApplication.shared.open(url)
    }
}
