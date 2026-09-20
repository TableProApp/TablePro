//
//  HostKeyVerifier.swift
//  TableProMobile
//
//  Checks a presented SSH host key against the known-hosts store before any
//  credential is sent, and asks the user when the key is new or has changed.
//

import Foundation
import TableProDatabase

enum HostKeyVerifier {
    static func verify(
        keyData: Data,
        keyType: String,
        hostname: String,
        port: Int,
        store: HostKeyStore = .shared,
        prompter: (any ConnectionPrompter)?
    ) async throws {
        let result = store.verify(
            keyData: keyData,
            keyType: keyType,
            hostname: hostname,
            port: port
        )

        switch result {
        case .trusted:
            return

        case let .unknown(fingerprint, presentedType):
            let prompt = ConnectionPrompt(
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
                confirmTitle: String(localized: "Trust")
            )
            try await decide(prompt, prompter: prompter, rejection: .hostKeyRejected(
                String(localized: "The server's host key was not trusted.")
            ))
            store.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)

        case let .mismatch(expected, actual):
            let prompt = ConnectionPrompt(
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
                style: .destructive
            )
            try await decide(prompt, prompter: prompter, rejection: .hostKeyRejected(
                String(localized: "The server's host key has changed.")
            ))
            store.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)
        }
    }

    /// Without a prompter there is no screen to ask from, which is every background caller:
    /// a Shortcut, Siri, or a widget. Those end with an error naming what to do instead of
    /// waiting on a question nobody can answer.
    private static func decide(
        _ prompt: ConnectionPrompt,
        prompter: (any ConnectionPrompter)?,
        rejection: SSHTunnelError
    ) async throws {
        guard let prompter else {
            throw SSHTunnelError.hostKeyUnverified(String(localized: """
                Open this connection in TablePro to check the server's SSH host key first.
                """))
        }
        guard await prompter.confirm(prompt) else { throw rejection }
    }

    private static func hostDisplay(_ hostname: String, _ port: Int) -> String {
        "[\(hostname)]:\(port)"
    }
}
