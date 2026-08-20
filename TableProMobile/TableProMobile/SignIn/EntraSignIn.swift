//
//  EntraSignIn.swift
//  TableProMobile
//
//  Microsoft Entra ID sign-in for SQL Server connections. The device code flow needs no redirect
//  URI and no in-app browser, so it works here with the system browser and a one-time code.
//

import Foundation
import Observation
import SwiftUI
import TableProPluginKit
import UIKit

@MainActor
@Observable
final class EntraSignInPresenter {
    static let shared = EntraSignInPresenter()

    struct Confirmation: Identifiable {
        let id = UUID()
        let message: String
        let respond: @MainActor (Bool) -> Void
    }

    struct CodeNotice: Identifiable {
        let id = UUID()
        let code: String
    }

    var pendingConfirmation: Confirmation?
    var pendingCode: CodeNotice?

    private init() {}

    /// Only one sign-in can be on screen at a time. A second connect racing the first is refused
    /// rather than queued, so no attempt waits on a prompt the user never sees.
    func confirm(message: String) async -> Bool {
        guard pendingConfirmation == nil else { return false }

        return await withCheckedContinuation { continuation in
            pendingConfirmation = Confirmation(message: message) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }

    func resolve(_ request: Confirmation, accepted: Bool) {
        guard pendingConfirmation?.id == request.id else { return }
        pendingConfirmation = nil
        request.respond(accepted)
    }

    /// Puts the code on the pasteboard and opens the verification page. Microsoft returns a bare
    /// URL and expects the code to be entered there, so it has to be shown as well as copied.
    func presentCode(_ code: String, url: URL) {
        UIPasteboard.general.string = code
        pendingCode = CodeNotice(code: code)
        UIApplication.shared.open(url)
    }
}

enum EntraSignIn {
    static func needsSignIn(_ error: Error) -> Bool {
        guard let entraError = error as? EntraOAuthError else { return false }
        return entraError.needsSignIn
    }

    /// Offers the sign-in and runs it. Returns true when it completed, so the caller can retry.
    static func offer(fields: [String: String]) async -> Bool {
        let confirmed = await EntraSignInPresenter.shared.confirm(
            message: String(localized: "Sign in to Microsoft Entra ID with your browser?")
        )
        guard confirmed else { return false }

        do {
            try await EntraCredentialResolver.shared.signIn(
                fields: fields,
                presentCode: { url, userCode in
                    Task { @MainActor in
                        EntraSignInPresenter.shared.presentCode(userCode, url: url)
                    }
                }
            )
            return true
        } catch {
            return false
        }
    }
}

struct EntraSignInPromptModifier: ViewModifier {
    @Bindable var presenter = EntraSignInPresenter.shared

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Microsoft Entra ID Sign-In Required"),
                isPresented: Binding(
                    get: { presenter.pendingConfirmation != nil },
                    set: { presenting in
                        guard !presenting, let request = presenter.pendingConfirmation else { return }
                        presenter.resolve(request, accepted: false)
                    }
                ),
                presenting: presenter.pendingConfirmation
            ) { request in
                Button(String(localized: "Sign In")) {
                    presenter.resolve(request, accepted: true)
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    presenter.resolve(request, accepted: false)
                }
            } message: { request in
                Text(request.message)
            }
            .alert(
                String(localized: "Finish Signing In"),
                isPresented: Binding(
                    get: { presenter.pendingCode != nil },
                    set: { presenting in
                        if !presenting { presenter.pendingCode = nil }
                    }
                ),
                presenting: presenter.pendingCode
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) {
                    presenter.pendingCode = nil
                }
            } message: { notice in
                Text(
                    String(
                        format: String(
                            localized: "Enter the code %@ in the browser to finish signing in. It is on your clipboard."
                        ),
                        notice.code
                    )
                )
            }
    }
}

extension View {
    func entraSignInPrompt() -> some View {
        modifier(EntraSignInPromptModifier())
    }
}
