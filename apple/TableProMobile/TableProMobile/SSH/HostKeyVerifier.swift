import Foundation
import TableProDatabase
import TableProSSHTransport

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

        case let .invalidHost(problem):
            throw SSHTunnelError.hostKeyRejected(problem.explanation)

        // Asking would offer a server whose key changed as a new one.
        case .unreadable:
            throw SSHTunnelError.hostKeyUnverified(String(localized: """
                The SSH host keys saved on this device could not be read, so this server's key could not be \
                checked.
                """))

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

    // No prompter means a background caller (a Shortcut, Siri, a widget), which gets an error instead of a question.
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
