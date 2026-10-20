import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

struct JumpHostCredentialTests {
    private let connectionId = UUID()

    @Test("Hop credentials read back as they were saved, under one account for the connection")
    func roundTrip() throws {
        let store = EphemeralSecureStore()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let credentials: [UUID: JumpHostCredential] = [
            first: .privateKey(key: "-----BEGIN OPENSSH PRIVATE KEY-----", passphrase: "secret"),
            second: .privateKey(key: "KEY TWO", passphrase: nil),
            third: .sshServerKey
        ]

        try JumpHostCredentialStore.save(credentials, for: connectionId, in: store)

        #expect(try JumpHostCredentialStore.load(for: connectionId, in: store) == credentials)
        #expect(try store.retrieve(forKey: "com.TablePro.jumphostkeys.\(connectionId.uuidString)") != nil)
    }

    @Test("A connection with no stored hop keys reads as an empty map")
    func absentReadsEmpty() throws {
        #expect(try JumpHostCredentialStore.load(for: connectionId, in: EphemeralSecureStore()).isEmpty)
    }

    @Test("A Keychain read that fails is reported, never read as no key")
    func readErrorThrows() {
        #expect(throws: RefusingSecureStore.ReadFailure.self) {
            try JumpHostCredentialStore.load(for: connectionId, in: RefusingSecureStore())
        }
    }

    @Test("Stored hop keys this build cannot decode are reported, never read as no key")
    func undecodableThrows() throws {
        let store = EphemeralSecureStore()
        try store.store(#"{"\#(UUID().uuidString)":{"agent":{}}}"#, forKey: ConnectionSecretKind.jumpHostKeys.account(for: connectionId))

        #expect(throws: DecodingError.self) {
            try JumpHostCredentialStore.load(for: connectionId, in: store)
        }
    }

    @Test("Saving an empty map deletes the item")
    func emptyMapDeletes() throws {
        let store = EphemeralSecureStore()
        try JumpHostCredentialStore.save([UUID(): .sshServerKey], for: connectionId, in: store)

        try JumpHostCredentialStore.save([:], for: connectionId, in: store)

        #expect(try store.retrieve(forKey: ConnectionSecretKind.jumpHostKeys.account(for: connectionId)) == nil)
    }

    @Test("The encoded map is what save stores, so a throwaway store reads it back")
    func encodeMatchesSave() throws {
        let hopId = UUID()
        let credentials: [UUID: JumpHostCredential] = [hopId: .privateKey(key: "KEY", passphrase: nil)]
        let encoded = try JumpHostCredentialStore.encode(credentials)
        let store = EphemeralSecureStore([ConnectionSecretKind.jumpHostKeys.account(for: connectionId): encoded])

        #expect(try JumpHostCredentialStore.load(for: connectionId, in: store) == credentials)
    }

    @Test("A replaced connection's hops take the stored ids by host, port and username, each id once")
    func keepingHopIdsMatchesEachStoredHopOnce() throws {
        let bastion = SSHJumpHost(host: "bastion.internal", port: nil, username: "jump")
        let twin = SSHJumpHost(host: "bastion.internal", port: 22, username: "jump")
        let inner = SSHJumpHost(host: "inner.internal", port: 2_222, username: "ops")
        let stored = SSHConfiguration(host: "db-ssh.internal", jumpHosts: [bastion, twin, inner])
        let incoming = SSHConfiguration(host: "db-ssh.internal", jumpHosts: [
            SSHJumpHost(host: "inner.internal", port: 2_222, username: "ops"),
            SSHJumpHost(host: "bastion.internal", port: 22, username: "jump"),
            SSHJumpHost(host: "bastion.internal", port: nil, username: "jump"),
            SSHJumpHost(host: "bastion.internal", port: 22, username: "jump"),
            SSHJumpHost(host: "inner.internal", port: 2_222, username: "root")
        ])

        let merged = try #require(JumpHostCredentialStore.keepingHopIds(from: stored, into: incoming))

        let ids = merged.jumpHosts.map(\.id)
        #expect(ids[0] == inner.id)
        #expect(ids[1] == bastion.id)
        #expect(ids[2] == twin.id)
        #expect(ids[3] == incoming.jumpHosts[3].id)
        #expect(ids[4] == incoming.jumpHosts[4].id)
        #expect(merged.jumpHosts.map(\.host) == incoming.jumpHosts.map(\.host))
    }

    @Test("Without a stored or an incoming tunnel the incoming one is kept as it is")
    func keepingHopIdsWithoutBothSides() {
        let incoming = SSHConfiguration(host: "db-ssh.internal", jumpHosts: [SSHJumpHost(host: "bastion.internal")])

        #expect(JumpHostCredentialStore.keepingHopIds(from: nil, into: incoming) == incoming)
        #expect(JumpHostCredentialStore.keepingHopIds(from: incoming, into: nil) == nil)
    }
}

private final class RefusingSecureStore: SecureStore {
    struct ReadFailure: Error {}

    func store(_ value: String, forKey key: String) throws {}

    func retrieve(forKey key: String) throws -> String? {
        throw ReadFailure()
    }

    func delete(forKey key: String) throws {}
}
