import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
struct LinkedFoldersModelTests {
    private let pool = EphemeralDefaultsPool()
    private let updates = PassthroughSubject<Void, Never>()

    private final class WatcherReloads {
        var count = 0
    }

    private func makeModel(
        _ storage: LinkedFolderStorage,
        reloads: WatcherReloads = WatcherReloads()
    ) -> LinkedFoldersModel {
        LinkedFoldersModel(
            storage: storage,
            updates: updates.eraseToAnyPublisher(),
            reloadWatcher: { reloads.count += 1 }
        )
    }

    @Test("Folders load when the model is made")
    func loadsInInit() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        let folder = LinkedFolder(path: "/tmp/team")
        storage.addFolder(folder)

        #expect(makeModel(storage).folders == [folder])
    }

    @Test("Adding a folder in the home folder stores it with a tilde and reloads the watcher")
    func addContractsHome() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        let reloads = WatcherReloads()
        let model = makeModel(storage, reloads: reloads)

        model.add(URL(fileURLWithPath: NSHomeDirectory() + "/Shared/team", isDirectory: true))

        #expect(model.folders.map { $0.path } == ["~/Shared/team"])
        #expect(storage.loadFolders().map { $0.path } == ["~/Shared/team"])
        #expect(reloads.count == 1)
    }

    @Test("Adding a folder that is already linked changes nothing")
    func addSkipsDuplicate() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        storage.addFolder(LinkedFolder(path: "/tmp/team"))
        let reloads = WatcherReloads()
        let model = makeModel(storage, reloads: reloads)

        model.add(URL(fileURLWithPath: "/tmp/team", isDirectory: true))

        #expect(model.folders.count == 1)
        #expect(storage.loadFolders().count == 1)
        #expect(reloads.count == 0)
    }

    @Test("Turning a folder off persists and reloads the watcher")
    func setEnabledPersists() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        let folder = LinkedFolder(path: "/tmp/team")
        storage.addFolder(folder)
        let reloads = WatcherReloads()
        let model = makeModel(storage, reloads: reloads)

        model.setEnabled(false, for: folder)
        model.setEnabled(false, for: folder)

        #expect(model.folders.first?.isEnabled == false)
        #expect(storage.loadFolders().first?.isEnabled == false)
        #expect(reloads.count == 1, "A second write of the same value is a no-op")
    }

    @Test("Removing a folder persists and reloads the watcher")
    func removePersists() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        let folder = LinkedFolder(path: "/tmp/team")
        storage.addFolder(folder)
        let reloads = WatcherReloads()
        let model = makeModel(storage, reloads: reloads)

        model.remove(folder)

        #expect(model.folders.isEmpty)
        #expect(storage.loadFolders().isEmpty)
        #expect(reloads.count == 1)
    }

    @Test("A change made elsewhere shows up when the watcher reports an update")
    func reloadsOnUpdate() throws {
        let storage = LinkedFolderStorage(defaults: try pool.make().defaults)
        let model = makeModel(storage)
        storage.addFolder(LinkedFolder(path: "/tmp/elsewhere"))

        #expect(model.folders.isEmpty)
        updates.send(())

        #expect(model.folders.map { $0.path } == ["/tmp/elsewhere"])
    }
}

@MainActor
struct TrustedLinksModelTests {
    private let pool = EphemeralDefaultsPool()

    private func key(_ scope: String, savedConnectionId: UUID? = nil) -> ExternalConnectionTrustKey {
        ExternalConnectionTrustKey(
            databaseType: "MySQL",
            host: "127.0.0.1",
            database: "db",
            username: "db",
            scopeName: scope,
            savedConnectionId: savedConnectionId
        )
    }

    private func seededDefaults(_ entries: [TrustedExternalConnection]) throws -> UserDefaults {
        let defaults = try pool.make().defaults
        defaults.set(try JSONEncoder().encode(entries), forKey: "com.TablePro.externalConnectionTrust.entries")
        return defaults
    }

    @Test("Entries list newest first with the saved connection's name")
    func entriesSortedWithNames() throws {
        let savedId = UUID()
        let defaults = try seededDefaults([
            TrustedExternalConnection(key: key("older"), trustedAt: Date(timeIntervalSince1970: 100)),
            TrustedExternalConnection(key: key("newer", savedConnectionId: savedId), trustedAt: Date(timeIntervalSince1970: 200)),
        ])
        var lookups = 0
        let model = TrustedLinksModel(store: ExternalConnectionTrustStore(defaults: defaults)) {
            lookups += 1
            return [savedId: "Shop"]
        }

        #expect(model.entries.map { $0.key.scopeName } == ["newer", "older"])
        #expect(model.entries.map { $0.savedConnectionName } == ["Shop", nil])
        #expect(lookups == 1, "Names resolve once per refresh")
    }

    @Test("Names are not looked up when no entry came from a saved connection")
    func noLookupWithoutSavedConnections() throws {
        let defaults = try seededDefaults([
            TrustedExternalConnection(key: key("ddev-shop"), trustedAt: Date(timeIntervalSince1970: 100)),
        ])
        var lookups = 0
        _ = TrustedLinksModel(store: ExternalConnectionTrustStore(defaults: defaults)) {
            lookups += 1
            return [:]
        }

        #expect(lookups == 0)
    }

    @Test("Forget and Forget All only narrow trust, and the list follows the store")
    func forgetNarrowsTrust() throws {
        let store = ExternalConnectionTrustStore(defaults: try pool.make().defaults)
        store.trust(key("ddev-shop"))
        store.trust(key("ddev-blog"))
        let model = TrustedLinksModel(store: store) { [:] }

        model.forget(key("ddev-shop"))

        #expect(model.entries.map { $0.key.scopeName } == ["ddev-blog"])
        #expect(store.isTrusted(key("ddev-shop")) == false)
        #expect(store.isTrusted(key("ddev-blog")))

        model.forgetAll()

        #expect(model.entries.isEmpty)
        #expect(store.entries().isEmpty)
    }

    @Test("A link trusted from a prompt shows up without a refresh")
    func followsOutsideTrust() throws {
        let store = ExternalConnectionTrustStore(defaults: try pool.make().defaults)
        let model = TrustedLinksModel(store: store) { [:] }

        store.trust(key("ddev-shop"))

        #expect(model.entries.map { $0.key.scopeName } == ["ddev-shop"])
    }
}
