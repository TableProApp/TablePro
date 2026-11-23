import CloudKit
import Foundation
@testable import TablePro
import TableProSSHConfig
import TableProSyncTransport
import Testing

@MainActor
struct SyncProfileDeletionTrustTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-profile-deletion-trust")
    }

    private var connectionsFileURL: URL {
        environment.directory.appendingPathComponent("connections.json")
    }

    // Same records, different bytes, tag left as it was: what any editor outside TablePro leaves behind.
    private func editConnectionsOutsideTablePro() throws {
        let original = try Data(contentsOf: connectionsFileURL)
        let object = try JSONSerialization.jsonObject(with: original)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: connectionsFileURL)
        environment.connections.invalidateCache()
        _ = environment.connections.loadConnections()
    }

    private func pullDeletion(of type: SyncRecordType, id: UUID) async -> Bool {
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        return await coordinator.applyPullResult(PullResult(
            changedRecords: [],
            deletedRecordIDs: [SyncRecordMapper.recordID(type: type, id: id.uuidString, in: Self.zoneID)],
            newToken: nil
        ))
    }

    private func expectStillUntrusted() {
        #expect(!environment.connections.storeIsTrusted)
        environment.connections.invalidateCache()
        _ = environment.connections.loadConnections()
        #expect(!environment.connections.storeIsTrusted)
    }

    @Test("An SSH profile deleted on another Mac converts its connections without signing a connections.json edited elsewhere")
    func remoteSSHProfileDeletionKeepsUntrustedFileUntrusted() async throws {
        let profiles = SSHProfileStorage(
            userDefaults: environment.defaults,
            keychain: environment.keychain,
            syncTracker: environment.tracker,
            connectionStorage: environment.connections
        )
        let profile = SSHProfile(name: "Bastion", host: "bastion.example.com", port: 22, username: "deploy", authMethod: .password)
        #expect(profiles.addProfile(profile))
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: profile.toSSHConfiguration())
        connection.sshConfig = profile.toSSHConfiguration()
        connection.sshProfileId = profile.id
        #expect(environment.connections.addConnection(connection))
        try editConnectionsOutsideTablePro()
        try #require(!environment.connections.storeIsTrusted)

        #expect(await pullDeletion(of: .sshProfile, id: profile.id))

        let converted = try #require(environment.connections.loadConnection(id: connection.id))
        #expect(!converted.isLinked(toSSHProfile: profile.id))
        #expect(converted.resolvedSSHConfig.host == "bastion.example.com")
        expectStillUntrusted()
    }

    @Test("A credential profile deleted on another Mac converts its connections without signing a connections.json edited elsewhere")
    func remoteCredentialProfileDeletionKeepsUntrustedFileUntrusted() async throws {
        let profiles = CredentialProfileStorage(
            fileURL: environment.directory.appendingPathComponent("credentialProfiles.json"),
            keychain: environment.keychain,
            syncTracker: environment.tracker,
            connectionStorage: environment.connections,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: environment.keychain))
        )
        let profile = CredentialProfile(name: "Prod reader", username: "app_reader", passwordMode: .stored)
        #expect(profiles.addProfile(profile))
        var connection = TestFixtures.makeConnection()
        connection.credentialMode = .profile(id: profile.id)
        connection.username = profile.username
        #expect(environment.connections.addConnection(connection))
        try editConnectionsOutsideTablePro()
        try #require(!environment.connections.storeIsTrusted)

        #expect(await pullDeletion(of: .credentialProfile, id: profile.id))

        let converted = try #require(environment.connections.loadConnection(id: connection.id))
        #expect(converted.credentialMode == .inline)
        #expect(converted.username == "app_reader")
        expectStillUntrusted()
    }
}
