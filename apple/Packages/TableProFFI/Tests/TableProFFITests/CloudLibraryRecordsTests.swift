import Foundation
import TableProFFI
import Testing

private final class NoSecrets: HostSecrets, Sendable {
    func load(connectionId: String, kind: SecretKindTag) throws -> String? { nil }
    func store(connectionId: String, kind: SecretKindTag, secret: String, label: String) throws {}
    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {}
    func delete(connectionId: String, kind: SecretKindTag) throws {}
    func deleteConnection(connectionId: String) throws {}
    func loadItem(item: SecretItemTag) throws -> String? { nil }
    func storeItem(item: SecretItemTag, secret: String) throws {}
    func deleteItem(item: SecretItemTag) throws {}
}

private func makeLibrary() throws -> ConnectionLibrary {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let core = try Core(config: HostConfig(clientVersion: "test", storageDir: folder.path), secrets: NoSecrets())
    return try core.library()
}

private func save(_ name: String, in library: ConnectionLibrary) async throws -> String {
    let record = ConnectionRecord(
        id: "",
        name: name,
        driverId: "postgres",
        host: "db.internal",
        port: 5_432,
        database: "app",
        username: "",
        integratedAuth: false,
        tls: TlsSettings(mode: .disable, caFile: nil, clientCertificate: nil, clientKey: nil, serverName: nil),
        ssh: nil,
        safeMode: .off,
        queryTimeoutSecs: nil,
        color: nil,
        groupId: nil,
        lastOpenedMs: nil,
        tags: []
    )
    let secrets = ConnectionSecrets(databasePassword: nil, sshPassword: nil, sshPassphrase: nil)
    return try await library.save(record: record, secrets: secrets).id
}

private let emptyRecords = CloudLibraryRecords(groups: [], connections: [])

@Test func aLibrarySendsItsRecordsAsTheMacWritesThemAndThenNothing() async throws {
    let library = try makeLibrary()
    let work = try await library.createGroup(name: "Work", parentId: nil)
    let id = try await save("production", in: library)
    try await library.moveToGroup(ids: [id], groupId: work.id, before: nil)
    try await library.setFavorite(id: id, favorite: true)

    let sent = try await library.cloudEdits(base: emptyRecords)

    #expect(sent.groups == [
        CloudGroupFields(
            groupId: work.id.uppercased(), name: "Work", color: "None", iconName: nil, parentId: nil, sortOrder: 0
        )
    ])
    #expect(sent.connections == [
        CloudConnectionFields(
            connectionId: id.uppercased(), name: "production", groupId: work.id.uppercased(), sortOrder: 0, isFavorite: 1
        )
    ])
    #expect(try await library.cloudEdits(base: sent) == emptyRecords)
}

@Test func aPullFilesAConnectionUnderAnotherMacsGroupAndSendsItsNameAndIconBackUnchanged() async throws {
    let library = try makeLibrary()
    let id = try await save("production", in: library)
    let groupId = UUID().uuidString
    let changed = CloudLibraryRecords(
        groups: [
            CloudGroupFields(
                groupId: groupId, name: "Clients\t", color: "Gray", iconName: "person.2", parentId: nil, sortOrder: 4
            )
        ],
        connections: [
            CloudConnectionFields(
                connectionId: id.uppercased(), name: "production", groupId: groupId, sortOrder: 9, isFavorite: 1
            )
        ]
    )

    try await library.applyCloudPull(pull: pull(base: emptyRecords, changed: changed))

    let snapshot = try await library.snapshot()
    #expect(snapshot.groups.map { $0.name } == ["Clients"])
    #expect(snapshot.groups.first?.color == "slate")
    #expect(snapshot.connections.first?.groupId == groupId.lowercased())
    #expect(snapshot.favorites == [id])
    #expect(try await library.cloudEdits(base: changed) == emptyRecords)
}

@Test func aPullKeepsThisMacsUnpushedRenameAndTakesAnotherMacsColour() async throws {
    let library = try makeLibrary()
    let groupId = UUID().uuidString
    let base = CloudLibraryRecords(
        groups: [
            CloudGroupFields(groupId: groupId, name: "Work", color: "None", iconName: nil, parentId: nil, sortOrder: 0)
        ],
        connections: []
    )
    try await library.applyCloudPull(pull: pull(base: emptyRecords, changed: base))
    try await library.renameGroup(id: groupId, name: "Office")
    var recoloured = base
    recoloured.groups[0].color = "Red"

    try await library.applyCloudPull(pull: pull(base: base, changed: recoloured))

    let snapshot = try await library.snapshot()
    #expect(snapshot.groups.map { $0.name } == ["Office"])
    #expect(snapshot.groups.first?.color == "red")
    var renamed = recoloured
    renamed.groups[0].name = "Office"
    #expect(try await library.cloudEdits(base: recoloured) == renamed)
}

private func pull(base: CloudLibraryRecords, changed: CloudLibraryRecords) -> CloudLibraryPull {
    CloudLibraryPull(
        base: base,
        changed: changed,
        deletedGroupIds: [],
        deletedConnectionIds: [],
        deletedHereGroupIds: [],
        deletedHereConnectionIds: [],
        favoritesOrder: nil
    )
}
