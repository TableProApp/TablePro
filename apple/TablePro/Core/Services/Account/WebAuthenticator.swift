//
//  WebAuthenticator.swift
//  TablePro
//

import AppKit
import AuthenticationServices
import Foundation

@MainActor
internal protocol WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL
}

// Opens the account pages in an ASWebAuthenticationSession sheet and returns the app.tablepro: redirect.
@MainActor
internal final class WebAuthenticationSessionAuthenticator: NSObject, WebAuthenticating,
    ASWebAuthenticationPresentationContextProviding {
    private let anchor: () -> NSWindow?
    private var session: ASWebAuthenticationSession?

    init(anchor: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.anchor = anchor
    }

    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        let result: Result<URL, AccountError> = await withCheckedContinuation { continuation in
            let completion: ASWebAuthenticationSession.CompletionHandler = { url, error in
                if let url {
                    continuation.resume(returning: .success(url))
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(returning: .failure(.canceled))
                } else {
                    continuation.resume(returning: .failure(.network(error?.localizedDescription ?? "")))
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme),
                    completionHandler: completion
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme,
                    completionHandler: completion
                )
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(returning: .failure(.canceled))
            }
        }
        session = nil
        return try result.get()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor() ?? ASPresentationAnchor()
        }
    }
}
