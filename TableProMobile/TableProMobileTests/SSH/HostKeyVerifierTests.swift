import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

@MainActor
@Suite("Host key verifier")
struct HostKeyVerifierTests {
    private final class RecordingPrompter: ConnectionPrompter, @unchecked Sendable {
        let answer: Bool
        private(set) var asked: [ConnectionPrompt] = []

        init(answer: Bool) {
            self.answer = answer
        }

        func confirm(_ prompt: ConnectionPrompt) async -> Bool {
            asked.append(prompt)
            return answer
        }
    }

    private func makeStore() -> HostKeyStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("known_hosts-\(UUID().uuidString)").path
        return HostKeyStore(filePath: path)
    }

    private func verify(
        store: HostKeyStore,
        prompter: (any ConnectionPrompter)?,
        key: Data = Data("ssh-key".utf8)
    ) async throws {
        try await HostKeyVerifier.verify(
            keyData: key,
            keyType: "ssh-ed25519",
            hostname: "db.example.com",
            port: 22,
            store: store,
            prompter: prompter
        )
    }

    @Test("An unknown host is trusted only after the user says so")
    func unknownHostTrustedOnAcceptance() async throws {
        let store = makeStore()
        let prompter = RecordingPrompter(answer: true)

        try await verify(store: store, prompter: prompter)

        #expect(prompter.asked.count == 1)
        #expect(prompter.asked.first?.style == .standard)
        #expect(store.trustedHosts().contains("[db.example.com]:22"))

        try await verify(store: store, prompter: prompter)
        #expect(prompter.asked.count == 1, "a trusted host asks nothing the second time")
    }

    @Test("Refusing an unknown host fails the tunnel and trusts nothing")
    func unknownHostRejected() async {
        let store = makeStore()
        let prompter = RecordingPrompter(answer: false)

        await #expect(throws: SSHTunnelError.self) {
            try await verify(store: store, prompter: prompter)
        }
        #expect(store.trustedHosts().isEmpty)
    }

    @Test("A changed host key asks with the destructive action")
    func changedKeyIsDestructive() async throws {
        let store = makeStore()
        store.trust(hostname: "db.example.com", port: 22, key: Data("old-key".utf8), keyType: "ssh-ed25519")
        let prompter = RecordingPrompter(answer: true)

        try await verify(store: store, prompter: prompter, key: Data("new-key".utf8))

        #expect(prompter.asked.first?.style == .destructive)
    }

    @Test("With no screen to ask from, an unknown host fails at once instead of waiting")
    func noPrompterFailsImmediately() async {
        let store = makeStore()

        await #expect(throws: SSHTunnelError.self) {
            try await verify(store: store, prompter: nil)
        }
        #expect(store.trustedHosts().isEmpty)
    }
}
