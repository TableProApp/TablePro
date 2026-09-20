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
            try await decide(
                .unknownHostKey(host: hostname, port: port, keyType: presentedType, fingerprint: fingerprint),
                prompter: prompter,
                rejected: .hostKeyRejected(String(localized: "The server's host key was not trusted.")),
                unanswerable: .hostKeyUnverified(String(localized: """
                    Open this connection in TablePro to check the server's SSH host key first.
                    """))
            )
            store.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)

        case let .mismatch(expected, actual):
            try await decide(
                .changedHostKey(
                    host: hostname,
                    port: port,
                    previousFingerprint: expected,
                    currentFingerprint: actual
                ),
                prompter: prompter,
                rejected: .hostKeyRejected(String(localized: "The server's host key has changed.")),
                unanswerable: .hostKeyUnverified(String(localized: """
                    The server's SSH host key has changed. Open this connection in TablePro to \
                    check it.
                    """))
            )
            store.trust(hostname: hostname, port: port, key: keyData, keyType: keyType)
        }
    }

    /// Without a prompter there is no screen to ask from, which is every background caller: a
    /// Shortcut, Siri, or a widget. Those end with an error naming what to do instead of waiting on
    /// a question nobody can answer.
    private static func decide(
        _ question: ConnectionQuestion,
        prompter: (any ConnectionPrompter)?,
        rejected: SSHTunnelError,
        unanswerable: SSHTunnelError
    ) async throws {
        guard let prompter else { throw unanswerable }
        guard await prompter.confirm(question) else { throw rejected }
    }
}
