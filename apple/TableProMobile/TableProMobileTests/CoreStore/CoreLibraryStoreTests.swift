import Foundation
import TableProFFI
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct CoreLibraryStoreTests {
    private let directory: URL
    private let defaults: UserDefaults
    private let secureStore = MockSecureStore()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.CoreLibrary.\(UUID().uuidString)"))
    }

    private var legacyConnectionsFile: URL { directory.appendingPathComponent("connections.json") }
    private var coreFile: URL { directory.appendingPathComponent("Core/connections.json") }

    private func makeStore() -> CoreLibraryStore {
        CoreLibraryStore(directory: directory, defaults: defaults, secureStore: secureStore, clientVersion: "test")
    }

    private func legacyConnections() throws -> [DatabaseConnection] {
        try JSONDecoder().decode([DatabaseConnection].self, from: Data(contentsOf: legacyConnectionsFile))
    }

    private func writeLegacy(_ connections: [DatabaseConnection]) throws {
        try JSONEncoder().encode(connections).write(to: legacyConnectionsFile)
    }

    // The core's own reading of its file, without the store under test.
    private func coreContents() async throws -> LibraryContents {
        let core = try Core(
            config: HostConfig(clientVersion: "test", storageDir: coreFile.deletingLastPathComponent().path),
            secrets: ConnectionKeychainSecrets(secureStore: MockSecureStore())
        )
        return try await core.library().libraryContents()
    }

    @Test("A first launch reads the previous stable's files into the core and leaves them as they were")
    func firstLaunchImportsTheLegacyFiles() async throws {
        let connection = DatabaseConnection(name: "Orders", type: .postgresql, host: "db", port: 5_432, isFavorite: true)
        try writeLegacy([connection])
        let before = try Data(contentsOf: legacyConnectionsFile)

        let loaded = try makeStore().load()

        #expect(loaded.connections.map(\.id) == [connection.id])
        #expect(loaded.tags == ConnectionTag.presets)
        let contents = try await coreContents()
        #expect(contents.connections.compactMap { UUID(uuidString: $0.connection.id) } == [connection.id])
        #expect(contents.favorites.compactMap(UUID.init(uuidString:)) == [connection.id])
        #expect(try Data(contentsOf: legacyConnectionsFile) == before)
    }

    @Test("A connection-string secret an older Mac synced moves to the Keychain before the core's file holds it")
    func mongoSecretNeverReachesTheCore() throws {
        let connection = DatabaseConnection(
            name: "Docs",
            type: .mongodb,
            host: "db.example.com",
            port: 27_017,
            additionalFields: ["mongoParam_tlsCertificateKeyFilePassword": "hunter2", "mongoParam_retryWrites": "true"]
        )
        try writeLegacy([connection])
        try Data(contentsOf: legacyConnectionsFile).write(to: legacyConnectionsFile.appendingPathExtension("backup"))

        let loaded = try makeStore().load()

        #expect(loaded.connections.first?.additionalFields == ["mongoParam_retryWrites": "true"])
        #expect(try secureStore.retrieve(forKey: ConnectionSecretKind.sslKeyPassphrase.account(for: connection.id)) == "hunter2")
        for file in [coreFile, legacyConnectionsFile, legacyConnectionsFile.appendingPathExtension("backup")] {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("hunter2"))
        }
    }

    @Test("A write reaches the core's store and the files the previous stable reads")
    func writeReachesBothSides() async throws {
        let store = makeStore()
        var library = try store.load()
        let added = DatabaseConnection(name: "Added", type: .mysql)
        library.connections.append(added)
        library.groups.append(ConnectionGroup(name: "Team"))

        try store.write(library, keepingPastedSSHKeys: [:])

        #expect(try await coreContents().connections.map(\.connection.name) == ["Added"])
        #expect(try legacyConnections().map(\.id) == [added.id])
        #expect(try makeStore().load() == library)
    }

    @Test("Projects and the project each top-level group and loose connection names live in the core's store")
    func projectsLiveInTheCoreStore() async throws {
        let store = makeStore()
        var library = try store.load()
        let acme = ConnectionProject(name: "Acme", color: .blue)
        let team = ConnectionGroup(name: "Team", projectId: acme.id)
        var loose = DatabaseConnection(name: "Loose", type: .mysql)
        loose.projectId = acme.id
        library.projects = [acme]
        library.groups = [team]
        library.connections = [loose]

        try store.write(library, keepingPastedSSHKeys: [:])

        let contents = try await coreContents()
        #expect(contents.projects.map(\.name) == ["Acme"])
        #expect(contents.groups.first?.projectId.flatMap(UUID.init(uuidString:)) == acme.id)
        #expect(contents.connections.first?.connection.projectId.flatMap(UUID.init(uuidString:)) == acme.id)
        let reloaded = try makeStore().load()
        #expect(reloaded.projects.map(\.id) == [acme.id])
        #expect(reloaded.groups.first?.projectId == acme.id)
        #expect(reloaded.connections.first?.projectId == acme.id)
    }

    @Test("An edit the previous stable made after a downgrade is taken in at the next launch")
    func previousStableEditIsTakenIn() throws {
        let store = makeStore()
        var library = try store.load()
        let connection = DatabaseConnection(name: "Orders", type: .postgresql)
        library.connections = [connection]
        try store.write(library, keepingPastedSSHKeys: [:])

        var renamed = connection
        renamed.name = "Renamed by the previous stable"
        try writeLegacy([renamed])

        #expect(try makeStore().load().connections.map(\.name) == ["Renamed by the previous stable"])
    }

    @Test("A launch whose files the previous stable did not change keeps the core's library")
    func unchangedLegacyKeepsTheCore() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        let mirrored = try Data(contentsOf: legacyConnectionsFile)

        #expect(try makeStore().load() == library)
        #expect(try Data(contentsOf: legacyConnectionsFile) == mirrored)
    }

    @Test("Files a write did not reach are written again at the next launch")
    func behindMirrorIsWrittenAgain() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        try writeLegacy([])
        var record = try #require(store.mirror.record)
        record.legacy = store.mirror.digest()
        record.legacyBehind = true
        store.mirror.record = record

        #expect(try makeStore().load() == library)
        #expect(try legacyConnections().map(\.name) == ["Orders"])
    }

    @Test("Files a crash left half written are finished from the core, not read back as the previous stable's")
    func halfWrittenMirrorIsFinished() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        let groupsFile = directory.appendingPathComponent("groups.json")
        let groupsBefore = try Data(contentsOf: groupsFile)
        library.groups = [ConnectionGroup(name: "Team")]
        library.connections[0].name = "Renamed"
        try store.write(library, keepingPastedSSHKeys: [:])
        // As a crash after connections.json landed and before groups.json did leaves them.
        try groupsBefore.write(to: groupsFile)
        var record = try #require(store.mirror.record)
        record.legacy = store.mirror.digest()
        record.legacyBehind = true
        store.mirror.record = record

        #expect(try makeStore().load() == library)
        let groups = try JSONDecoder().decode([ConnectionGroup].self, from: Data(contentsOf: groupsFile))
        #expect(groups.map(\.name) == ["Team"])
    }

    @Test("A stop after a file landed and before the record moved on still reads as this build's write")
    func stopBeforeTheRecordMovedIsFinished() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        let before = store.mirror.digest()
        let groupsFile = directory.appendingPathComponent("groups.json")
        let groupsBefore = try Data(contentsOf: groupsFile)
        library.groups = [ConnectionGroup(name: "Team")]
        library.connections[0].name = "Renamed"
        try store.write(library, keepingPastedSSHKeys: [:])
        try groupsBefore.write(to: groupsFile)
        var record = try #require(store.mirror.record)
        record.legacy = before
        record.legacyPending = store.mirror.digest()
        record.legacyBehind = true
        store.mirror.record = record

        #expect(try makeStore().load() == library)
    }

    @Test("The previous stable's copy of a connection the core holds unread stays in its file")
    func legacyCopyOfHeldConnectionStays() throws {
        let store = makeStore()
        var library = try store.load()
        let held = DatabaseConnection(name: "Held", type: .postgresql)
        library.connections = [held, DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: coreFile)) as? [String: Any])
        var entries = try #require(document["connections"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["id"] as? String)?.lowercased() == held.id.uuidString.lowercased() })
        entries[index]["auth_mode"] = "from_the_future"
        document["connections"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: coreFile)

        let reopened = makeStore()
        var current = try reopened.load()
        #expect(current.connections.map(\.name) == ["Orders"])
        #expect(reopened.unreadable.connections == [held.id])
        current.connections[0].name = "Renamed"
        try reopened.write(current, keepingPastedSSHKeys: [:])

        #expect(try legacyConnections().map(\.name) == ["Renamed", "Held"])
    }

    @Test("A removal the previous stable's files did not take fails the write, so it is tried again")
    func untakenRemovalFailsTheWrite() throws {
        let held = UUID()
        let groupsFile = directory.appendingPathComponent("groups.json")
        try Data(#"[{"id":"\#(held.uuidString)","name":7}]"#.utf8).write(to: groupsFile)
        let store = makeStore()
        let library = try store.load()
        #expect(store.unreadable.groups == [held])
        try FileManager.default.removeItem(at: groupsFile)
        try FileManager.default.createDirectory(at: groupsFile, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try store.write(library, keepingPastedSSHKeys: [:], removingUnreadable: UnreadableCopies(groups: [held]))
        }
        #expect(store.unreadable.groups == [held])
        try FileManager.default.removeItem(at: groupsFile)
        try store.write(library, keepingPastedSSHKeys: [:], removingUnreadable: UnreadableCopies(groups: [held]))
        #expect(store.unreadable.groups.isEmpty)
    }

    @Test("A core file that no longer parses is set aside and the library comes back from the previous stable's files")
    func damagedCoreFileIsSetAside() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        let damaged = Data(#"{"version":1,"connections":["#.utf8)
        try damaged.write(to: coreFile)

        let reopened = makeStore()
        #expect(try reopened.load() == library)
        #expect(try Data(contentsOf: reopened.unreadableCopyURL) == damaged)
        #expect(try Data(contentsOf: coreFile) != damaged)
    }

    @Test("A core file cut to nothing is set aside, and the library comes back from the previous stable's files")
    func blankCoreFileIsSetAside() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        try Data(" \n".utf8).write(to: coreFile)

        let reopened = makeStore()
        #expect(try reopened.load() == library)
        #expect(try legacyConnections().map(\.name) == ["Orders"])
        #expect(try Data(contentsOf: reopened.unreadableCopyURL) == Data(" \n".utf8))
    }

    @Test("A newer build's core file is never written over")
    func newerCoreFileIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: coreFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version":99,"connections":[]}"#.utf8)
        try newer.write(to: coreFile)
        let store = makeStore()

        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: CoreLibraryStore.Failure.notLoaded) {
            try store.write(CoreLibraryStore.Library(connections: [], groups: [], tags: [], projects: []), keepingPastedSSHKeys: [:])
        }
        #expect(try Data(contentsOf: coreFile) == newer)
    }

    @Test("Previous stable files that changed and no longer read stop every write")
    func unreadableLegacyChangeFailsTheLoad() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        try FileManager.default.removeItem(at: legacyConnectionsFile.appendingPathExtension("backup"))
        try Data("{ not json".utf8).write(to: legacyConnectionsFile)

        #expect(throws: (any Error).self) { try makeStore().load() }
    }

    @Test("Values only the core holds survive an iOS edit")
    func coreOnlyValuesSurviveAnEdit() async throws {
        let store = makeStore()
        var library = try store.load()
        let connection = DatabaseConnection(name: "Orders", type: .postgresql)
        library.connections = [connection]
        try store.write(library, keepingPastedSSHKeys: [:])

        let core = try Core(
            config: HostConfig(clientVersion: "test", storageDir: coreFile.deletingLastPathComponent().path),
            secrets: ConnectionKeychainSecrets(secureStore: MockSecureStore())
        )
        let direct = try core.library()
        var contents = try await direct.libraryContents()
        contents.connections[0].details.startupSql = "SET search_path = app"
        contents.connections[0].connection.safeMode = .safeModeFull
        _ = try await direct.replaceLibrary(
            library: LibraryWriteRecord(
                connections: contents.connections,
                groups: contents.groups,
                tags: contents.tags,
                favorites: contents.favorites,
                projects: contents.projects,
                removing: []
            ),
            over: contents.digest
        )

        let reopened = makeStore()
        var edited = try reopened.load()
        #expect(edited.connections.first?.safeModeLevel == .confirmWrites)
        edited.connections[0].name = "Renamed"
        try reopened.write(edited, keepingPastedSSHKeys: [:])

        let after = try await coreContents().connections[0]
        #expect(after.connection.name == "Renamed")
        #expect(after.connection.safeMode == .safeModeFull)
        #expect(after.details.startupSql == "SET search_path = app")
    }

    @Test("A write that drops a connection the core holds unread lands over the file the deletion left")
    func writeAfterDroppingAHeldConnectionLands() throws {
        let store = makeStore()
        var library = try store.load()
        let held = DatabaseConnection(name: "Held", type: .postgresql)
        library.connections = [held, DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: coreFile)) as? [String: Any])
        var entries = try #require(document["connections"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { ($0["id"] as? String)?.lowercased() == held.id.uuidString.lowercased() })
        entries[index]["auth_mode"] = "from_the_future"
        document["connections"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: coreFile)

        let reopened = makeStore()
        var current = try reopened.load()
        current.connections[0].name = "Renamed"
        try reopened.write(current, keepingPastedSSHKeys: [:], removingUnreadable: UnreadableCopies(connections: [held.id]))

        #expect(reopened.unreadable.connections.isEmpty)
        #expect(try makeStore().load().connections.map(\.name) == ["Renamed"])
    }

    @Test("A write over a core file another process changed since the store read it is refused")
    func writeOverAChangedCoreFileIsRefused() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        let swapped = try String(contentsOf: coreFile, encoding: .utf8).replacingOccurrences(of: "Orders", with: "Planted")
        try Data(swapped.utf8).write(to: coreFile)

        library.connections[0].name = "Renamed"
        #expect(throws: (any Error).self) { try store.write(library, keepingPastedSSHKeys: [:]) }
        #expect(try String(contentsOf: coreFile, encoding: .utf8) == swapped)
    }

    @Test("A write after the core's file went missing writes it again, since no other writer's copy is under it")
    func writeAfterTheCoreFileWentMissingLands() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        try FileManager.default.removeItem(at: coreFile)

        library.connections[0].name = "Renamed"
        try store.write(library, keepingPastedSSHKeys: [:])

        #expect(try String(contentsOf: coreFile, encoding: .utf8).contains("Renamed"))
        #expect(try makeStore().load().connections.map(\.name) == ["Renamed"])
    }

    @Test("A write that names one id twice, or a record this build cannot read, is refused")
    func refusedWrites() throws {
        let store = makeStore()
        var library = try store.load()
        let connection = DatabaseConnection(name: "Orders", type: .postgresql)
        library.connections = [connection, connection]
        #expect(throws: CoreLibraryStore.Failure.repeatedId) { try store.write(library, keepingPastedSSHKeys: [:]) }

        let held = UUID()
        try Data(#"[{"id":"\#(held.uuidString)","name":5}]"#.utf8).write(to: legacyConnectionsFile)
        let reopened = makeStore()
        var current = try reopened.load()
        #expect(reopened.unreadable.connections == [held])
        current.connections = [DatabaseConnection(id: held, name: "Taken", type: .mysql)]
        #expect(throws: CoreLibraryStore.Failure.heldByUnreadableRecord(held)) {
            try reopened.write(current, keepingPastedSSHKeys: [:])
        }
    }

    @Test("A write that moves secrets out drops the core copy set aside before it")
    func secretsMovedOutDropTheSetAsideCopy() throws {
        let store = makeStore()
        var library = try store.load()
        library.connections = [DatabaseConnection(name: "Orders", type: .postgresql)]
        try store.write(library, keepingPastedSSHKeys: [:])
        try Data("{".utf8).write(to: coreFile)
        let reopened = makeStore()
        let loaded = try reopened.load()
        #expect(FileManager.default.fileExists(atPath: reopened.unreadableCopyURL.path))

        try reopened.write(loaded, keepingPastedSSHKeys: [:], removingSecrets: true)

        #expect(!FileManager.default.fileExists(atPath: reopened.unreadableCopyURL.path))
    }

    @Test("An older build's SSL require and a dropped profile link survive the core")
    func deviceFlagsSurvive() throws {
        let store = makeStore()
        var library = try store.load()
        var connection = DatabaseConnection(name: "Orders", type: .postgresql, sslEnabled: true)
        connection.sslConfiguration = SSLConfiguration(mode: .require, isLegacyRequire: true)
        connection.clearsSSHProfileLink = true
        library.connections = [connection]
        try store.write(library, keepingPastedSSHKeys: [:])

        let read = try #require(try makeStore().load().connections.first)
        #expect(read.sslConfiguration?.isLegacyRequire == true)
        #expect(read.clearsSSHProfileLink)
        let stored = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: legacyConnectionsFile)) as? [[String: Any]]
        )
        #expect((stored.first?["sslConfiguration"] as? [String: Any])?["mode"] as? String == "require")
    }
}
