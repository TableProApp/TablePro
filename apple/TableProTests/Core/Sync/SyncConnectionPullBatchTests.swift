import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncConnectionPullBatchTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private struct LibraryWork: Equatable {
        let reads: Int
        let writes: Int
    }

    private static func pull(_ records: [CKRecord]) -> PullResult {
        PullResult(changedRecords: records, deletedRecordIDs: [], newToken: nil)
    }

    private static func remoteConnections(_ count: Int) -> [DatabaseConnection] {
        (0..<count).map { TestFixtures.makeConnection(name: "Remote \($0)") }
    }

    // First sync on a new Mac: every connection arrives in one pull.
    private func pullIntoEmptyLibrary(_ connections: [DatabaseConnection]) async throws -> (LibraryWork, [DatabaseConnection]) {
        let environment = try SyncTestEnvironment(label: "sync-connection-pull-batch")
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let readsBefore = environment.connections.fileReadCount
        let writesBefore = environment.connections.fileWriteCount

        let applied = await coordinator.applyPullResult(
            Self.pull(connections.map { SyncRecordMapper.toCKRecord($0, in: Self.zoneID) }),
            settings: .default
        )

        #expect(applied)
        let work = LibraryWork(
            reads: environment.connections.fileReadCount - readsBefore,
            writes: environment.connections.fileWriteCount - writesBefore
        )
        return (work, environment.connections.loadConnections())
    }

    // Each record used to read, verify, decode, encode and write the whole library: 300 of each at 300 connections.
    @Test("A pull reads and writes the library the same number of times for 10 connections as for 300")
    func pullWorkDoesNotGrowWithTheBatch() async throws {
        let few = Self.remoteConnections(10)
        let many = Self.remoteConnections(300)

        let (fewWork, fewStored) = try await pullIntoEmptyLibrary(few)
        let (manyWork, manyStored) = try await pullIntoEmptyLibrary(many)

        #expect(fewWork.writes == 1)
        #expect(manyWork == fewWork)
        let fewIds = fewStored.map(\.id)
        let manyIds = manyStored.map(\.id)
        #expect(fewIds == few.map(\.id))
        #expect(manyIds == many.map(\.id))
        let allSynced = manyStored.allSatisfy { $0.origin == .synced }
        #expect(allSynced)
    }

    @Test("A credential profile that arrives after a connection still writes its username through to it")
    func profileAfterAConnectionSeesTheConnection() async throws {
        let environment = try SyncTestEnvironment(label: "sync-connection-pull-order")
        let profile = CredentialProfile(name: "Prod", username: "profile-user")
        var local = TestFixtures.makeConnection(name: "Linked")
        local.username = "local-user"
        local.credentialMode = .profile(id: profile.id)
        #expect(environment.connections.saveConnections([local]))
        var remote = local
        remote.username = "remote-user"
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        let applied = await coordinator.applyPullResult(
            Self.pull([
                SyncRecordMapper.toCKRecord(remote, in: Self.zoneID),
                SyncRecordMapper.toCKRecord(profile, in: Self.zoneID),
            ]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.connections.loadConnection(id: local.id)?.username == "profile-user")
    }

    @Test("A pull whose library cannot be read writes none of its connections and is not acknowledged")
    func unreadableLibraryRefusesTheWholeBatch() async throws {
        let environment = try SyncTestEnvironment(label: "sync-connection-pull-unreadable")
        let fileURL = environment.directory.appendingPathComponent("connections.json")
        let garbage = Data("not a connection list".utf8)
        try garbage.write(to: fileURL)
        environment.connections.invalidateCache()
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
        let writesBefore = environment.connections.fileWriteCount

        let applied = await coordinator.applyPullResult(
            Self.pull(Self.remoteConnections(3).map { SyncRecordMapper.toCKRecord($0, in: Self.zoneID) }),
            settings: .default
        )

        #expect(!applied)
        #expect(environment.connections.fileWriteCount == writesBefore)
        #expect(try Data(contentsOf: fileURL) == garbage)
    }
}
