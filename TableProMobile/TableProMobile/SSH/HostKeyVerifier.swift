//
//  HostKeyVerifier.swift
//  TableProMobile
//
//  Checks a presented SSH host key against the known-hosts store before any
//  credential is sent, and asks the user when the key is new or has changed.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class HostKeyPromptPresenter {
    static let shared = HostKeyPromptPresenter()

    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmTitle: String
        let isDestructive: Bool
        let respond: @MainActor (Bool) -> Void
    }

    var pending: Request?

    private init() {}

    /// Only one key decision can be on screen at a time. A second connect racing the
    /// first is refused rather than queued, so no attempt is left waiting on a prompt
    /// the user never sees.
    func ask(title: String, message: String, confirmTitle: String, isDestructive: Bool) async -> Bool {
        guard pending == nil else { return false }

        return await withCheckedContinuation { continuation in
            pending = Request(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                isDestructive: isDestructive
            ) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }

    func resolve(_ request: Request, accepted: Bool) {
        guard pending?.id == request.id else { return }
        pending = nil
        request.respond(accepted)
    }
}

enum HostKeyVerifier {
    static func verify(keyData: Data, keyType: String, hostname: String, port: Int) async throws {
        let result = HostKeyStore.shared.verify(
            keyData: keyData,
            keyType: keyType,
            hostname: hostname,
            port: port
        )

        switch result {
        case .trusted:
            return

        case let .unknown(fingerprint, presentedType):
            let accepted = await HostKeyPromptPresenter.shared.ask(
                title: String(localized: "Unknown SSH Server"),
                message: String(
                    format: String(localized: """
                        TablePro has not connected to %@ before.

                        %@ key fingerprint:
                        %@

                        Trust this server only if the fingerprint matches the one you expect.
                        """),
                    hostDisplay(hostname, port),
                    presentedType,
                    fingerprint
                ),
                confirmTitle: String(localized: "Trust"),
                isDestructive: false
            )
            guard accepted else {
                throw SSHTunnelError.hostKeyRejected(String(localized: "The server's host key was not trusted."))
            }
            HostKeyStore.shared.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)

        case let .mismatch(expected, actual):
            let accepted = await HostKeyPromptPresenter.shared.ask(
                title: String(localized: "SSH Host Key Changed"),
                message: String(
                    format: String(localized: """
                        The host key for %@ has changed.

                        This can mean the server was rebuilt, or that someone is intercepting \
                        the connection.

                        Previous fingerprint:
                        %@

                        Current fingerprint:
                        %@
                        """),
                    hostDisplay(hostname, port),
                    expected,
                    actual
                ),
                confirmTitle: String(localized: "Connect Anyway"),
                isDestructive: true
            )
            guard accepted else {
                throw SSHTunnelError.hostKeyRejected(String(localized: "The server's host key has changed."))
            }
            HostKeyStore.shared.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)
        }
    }

    private static func hostDisplay(_ hostname: String, _ port: Int) -> String {
        "[\(hostname)]:\(port)"
    }
}

struct HostKeyPromptModifier: ViewModifier {
    @Bindable var presenter = HostKeyPromptPresenter.shared

    func body(content: Content) -> some View {
        content.alert(
            presenter.pending?.title ?? "",
            isPresented: Binding(
                get: { presenter.pending != nil },
                set: { presenting in
                    guard !presenting, let request = presenter.pending else { return }
                    presenter.resolve(request, accepted: false)
                }
            ),
            presenting: presenter.pending
        ) { request in
            Button(request.confirmTitle, role: request.isDestructive ? .destructive : nil) {
                presenter.resolve(request, accepted: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                presenter.resolve(request, accepted: false)
            }
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func hostKeyPrompt() -> some View {
        modifier(HostKeyPromptModifier())
    }
}
