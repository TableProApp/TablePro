import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTheme
import Testing

@MainActor
struct AppHostSettingsStoresTests {
    @MainActor
    private final class Harness {
        let pool: EphemeralDefaultsPool
        let root: URL
        let storage: AppSettingsStorage
        let storageDefaults: UserDefaults
        let manager: AppSettingsManager
        let slashCommands: CustomSlashCommandStorage
        let slashCommandDefaults: UserDefaults
        let columnLayouts: FileColumnLayoutPersister
        let themes: ThemeCatalog
        let stores: AppHostSettingsStores

        init() throws {
            let pool = EphemeralDefaultsPool()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppHostSettingsStoresTests-\(UUID().uuidString)", isDirectory: true)
            let journal = SyncHostJournal()
            let trash = root.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let themes = ThemeCatalog(
                userDirectory: root.appendingPathComponent("Themes", isDirectory: true),
                bundleDirectory: nil,
                fileTrash: .folder(trash),
                syncJournal: journal
            )
            let storageDefaults = try pool.make().defaults
            let storage = AppSettingsStorage(userDefaults: storageDefaults)
            let manager = AppSettingsManager(
                storage: storage,
                themeEngine: ThemeEngine(catalog: themes),
                syncJournal: journal,
                appEvents: AppEvents(),
                passwordSyncDefaults: try pool.make().defaults,
                switchSync: { _ in },
                changeSyncCategories: {}
            )
            let slashCommandDefaults = try pool.make().defaults
            let slashCommands = CustomSlashCommandStorage(defaults: slashCommandDefaults, syncJournal: journal)
            let columnLayouts = FileColumnLayoutPersister(
                storageDirectory: root.appendingPathComponent("ColumnLayout", isDirectory: true),
                defaults: try pool.make().defaults,
                syncJournal: journal
            )
            self.pool = pool
            self.root = root
            self.storage = storage
            self.storageDefaults = storageDefaults
            self.manager = manager
            self.slashCommands = slashCommands
            self.slashCommandDefaults = slashCommandDefaults
            self.columnLayouts = columnLayouts
            self.themes = themes
            stores = AppHostSettingsStores(
                manager: manager,
                storage: storage,
                slashCommands: slashCommands,
                columnLayouts: columnLayouts,
                themes: themes
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func catalog() -> HostSettingsCatalog {
            HostSettingsCatalog(
                stores: stores,
                keptFile: JSONFileStore(url: root.appendingPathComponent("kept.json")),
                build: "1"
            )
        }
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        try #require(try data.map { try JSONSerialization.jsonObject(with: $0) } as? [String: Any])
    }

    private static func theme(_ id: String) throws -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            name: id,
            author: "",
            appearance: .dark,
            overrides: [.editorBackground: try ThemeColor(validating: "#224466")]
        )
    }

    @Test("Only a category saved on this Mac is reported, so defaults never go up over another Mac's choice")
    func onlySavedCategoriesAreReported() throws {
        let harness = try Harness()
        #expect(try harness.stores.documents().isEmpty)

        harness.manager.tabs = TabSettings(enablePreviewTabs: false)

        let documents = try harness.stores.documents()
        #expect(Set(documents.keys) == ["tabs"])
        #expect(try Self.object(documents["tabs"])["enablePreviewTabs"] as? Bool == false)
    }

    @Test("A pulled preferences category takes effect through Settings")
    func pulledPreferencesApply() throws {
        let harness = try Harness()

        let written = try harness.stores.write(Data(#"{"enablePreviewTabs":false}"#.utf8), for: "tabs")

        #expect(written == .written)
        #expect(harness.manager.tabs.enablePreviewTabs == false)
        #expect(harness.storage.loadTabs().enablePreviewTabs == false)
    }

    @Test("Two commands pulled under one name are told apart, and the rename goes up")
    func slashCommandCollisionsAreRenamed() throws {
        let harness = try Harness()
        let first = CustomSlashCommand(name: "explain", promptTemplate: "a")
        let second = CustomSlashCommand(name: "explain", promptTemplate: "b")

        _ = try harness.stores.write(try JSONEncoder().encode([first, second]), for: CustomSlashCommandStorage.syncCategory)

        #expect(harness.slashCommands.commands.map(\.name) == ["explain", "explain-2"])
        let reported = try harness.catalog().categories()[CustomSlashCommandStorage.syncCategory]
        let names = try #require(try reported.map { try JSONDecoder().decode([CustomSlashCommand].self, from: $0) })
        #expect(names.map(\.name) == ["explain", "explain-2"])
    }

    @Test("An empty command list once saved is reported, so removing the last command reaches other Macs")
    func emptySavedCommandListIsReported() throws {
        let harness = try Harness()
        let command = CustomSlashCommand(name: "explain", promptTemplate: "a")
        try harness.slashCommands.add(command)
        harness.slashCommands.delete(id: command.id)

        let reported = try harness.stores.documents()[CustomSlashCommandStorage.syncCategory]

        #expect(reported.map { String(decoding: $0, as: UTF8.self) } == "[]")
    }

    @Test("A column layout is written, read back and removed")
    func columnLayoutRoundTrip() throws {
        let harness = try Harness()
        let key = ColumnLayoutTableKey(connectionId: UUID(), databaseName: "db", schemaName: "public", tableName: "users")
        let category = FileColumnLayoutPersister.syncCategory(for: key.storageKey)

        _ = try harness.stores.write(Data(#"{"columnWidths":{"email":220,"id":40}}"#.utf8), for: category)

        #expect(harness.columnLayouts.load(for: key)?.columnWidths == ["email": 220, "id": 40])
        #expect(try Self.object(try harness.stores.documents()[category])["columnWidths"] as? [String: Double] == [
            "email": 220, "id": 40,
        ])

        try harness.stores.remove(category)

        #expect(harness.columnLayouts.load(for: key) == nil)
        #expect(try harness.stores.documents()[category] == nil)
    }

    @Test("A theme is written, read back and removed")
    func themeRoundTrip() throws {
        let harness = try Harness()
        let theme = try Self.theme("user.ocean")
        let category = ThemeCatalog.syncCategory(for: theme.id)

        _ = try harness.stores.write(try ThemeFileFormat.encode(theme), for: category)

        #expect(harness.themes.storedTheme(id: theme.id) == theme)
        #expect(try harness.stores.documents()[category] == (try ThemeFileFormat.encode(theme)))

        try harness.stores.remove(category)

        #expect(harness.themes.storedTheme(id: theme.id) == nil)
        #expect(try harness.stores.documents()[category] == nil)
    }

    @Test("A theme this build refuses leaves the catalog alone and goes back as sent")
    func refusedThemeGoesBackAsSent() throws {
        let harness = try Harness()
        let category = ThemeCatalog.syncCategory(for: "user.newer")
        let sent = Data(#"{"id":"user.newer","schema":999}"#.utf8)
        let catalog = harness.catalog()

        try catalog.apply(category, document: sent)

        #expect(harness.themes.storedTheme(id: "user.newer") == nil)
        #expect(try catalog.categories()[category] == (try SettingsJSON.canonical(try SettingsJSON.parse(sent))))
    }

    @Test("An option a newer build added to a preferences category goes back as sent")
    func newerOptionGoesBackAsSent() throws {
        let harness = try Harness()
        let catalog = harness.catalog()

        try catalog.apply("tabs", document: Data(#"{"enablePreviewTabs":false,"newerOption":3}"#.utf8))

        #expect(harness.manager.tabs.enablePreviewTabs == false)
        let reported = try Self.object(try catalog.categories()["tabs"])
        #expect(reported["newerOption"] as? Int == 3)
        #expect(reported["enablePreviewTabs"] as? Bool == false)
    }

    @Test("A damaged column layout file fails the read, and a pull never writes over it")
    func damagedLayoutFileFailsTheRead() throws {
        let harness = try Harness()
        let connection = UUID()
        let key = ColumnLayoutTableKey(connectionId: connection, databaseName: "db", schemaName: nil, tableName: "t")
        try Data("not json".utf8).write(to: harness.root
            .appendingPathComponent("ColumnLayout/\(connection.uuidString).json", isDirectory: false))

        #expect(throws: (any Error).self) { try harness.stores.documents() }
        #expect(throws: (any Error).self) {
            try harness.stores.write(Data(#"{"columnWidths":{"id":40}}"#.utf8), for: FileColumnLayoutPersister.syncCategory(for: key.storageKey))
        }
        let left = try Data(contentsOf: harness.root.appendingPathComponent("ColumnLayout/\(connection.uuidString).json"))
        #expect(left == Data("not json".utf8))
    }

    @Test("A pulled layout whose write fails is not taken as stored")
    func failedLayoutWriteIsNotStored() throws {
        let harness = try Harness()
        let blocked = harness.root.appendingPathComponent("NotADirectory", isDirectory: false)
        try Data().write(to: blocked)
        let persister = FileColumnLayoutPersister(
            storageDirectory: blocked,
            defaults: try harness.pool.make().defaults,
            syncJournal: SyncHostJournal()
        )
        let key = ColumnLayoutTableKey(connectionId: UUID(), databaseName: "db", schemaName: nil, tableName: "t")

        #expect(throws: (any Error).self) {
            try persister.applyPulled(storageKey: key.storageKey, data: Data(#"{"columnWidths":{"id":40}}"#.utf8))
        }
        #expect(persister.load(for: key) == nil)
    }

    @Test("A theme file that no longer loads fails the read, so its theme never reads as deleted")
    func damagedThemeFileFailsTheRead() throws {
        let harness = try Harness()
        let themes = harness.root.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try Data(#"{"schema":4,"id":"user.broken""#.utf8).write(to: themes.appendingPathComponent("broken.json"))
        harness.themes.reloadSynchronously()

        #expect(throws: (any Error).self) { try harness.stores.documents() }
    }

    @Test("A theme file a newer build wrote goes by its id, as its bytes")
    func newerThemeFileGoesAsItsBytes() throws {
        let harness = try Harness()
        let themes = harness.root.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let bytes = Data(#"{"appearance":"dark","id":"user.newer","name":"Newer","schema":99}"#.utf8)
        try bytes.write(to: themes.appendingPathComponent("user.newer.json"))
        harness.themes.reloadSynchronously()

        let documents = try harness.stores.documents()

        #expect(documents[ThemeCatalog.syncCategory(for: "user.newer")] == bytes)
    }

    @Test("Saved slash commands that no longer decode fail the read rather than reading as every command removed")
    func unreadableSlashCommandsFailTheRead() throws {
        let harness = try Harness()
        harness.slashCommandDefaults.set(Data("not json".utf8), forKey: "ai.customSlashCommands.v1")

        #expect(throws: (any Error).self) { try harness.stores.documents() }
    }

    @Test("A theme file the catalog has not listed yet is read, not left out")
    func unlistedThemeFileIsRead() throws {
        let harness = try Harness()
        let theme = try Self.theme("user.dropped")
        let themes = harness.root.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try ThemeFileFormat.encode(theme).write(to: themes.appendingPathComponent("dropped.json"))

        let documents = try harness.stores.documents()

        #expect(documents[ThemeCatalog.syncCategory(for: theme.id)] == (try ThemeFileFormat.encode(theme)))
    }

    @Test("A themes folder that cannot be listed fails the read rather than reading as every theme removed")
    func unlistableThemesFolderFailsTheRead() throws {
        let harness = try Harness()
        let notAFolder = harness.root.appendingPathComponent("ThemesFile", isDirectory: false)
        try Data().write(to: notAFolder)
        let catalog = ThemeCatalog(
            userDirectory: notAFolder,
            bundleDirectory: nil,
            fileTrash: .folder(harness.root.appendingPathComponent("Trash", isDirectory: true)),
            syncJournal: SyncHostJournal()
        )

        #expect(throws: (any Error).self) { try catalog.syncPayloads() }
    }

    @Test("A saved preferences category that no longer decodes fails the read rather than reading as the defaults")
    func unreadablePreferencesFailTheRead() throws {
        let harness = try Harness()
        harness.storageDefaults.set(Data("not json".utf8), forKey: "com.TablePro.settings.tabs")

        #expect(throws: (any Error).self) { try harness.stores.documents() }
    }

    @Test("A pulled category equal to the defaults is saved, so an edit of one option keeps the newer one")
    func pulledDefaultsAreSaved() throws {
        let harness = try Harness()
        let catalog = harness.catalog()

        try catalog.apply("tabs", document: Data(#"{"enablePreviewTabs":true,"newerOption":3}"#.utf8))
        harness.manager.tabs = TabSettings(enablePreviewTabs: false)

        #expect(harness.storage.storedData(forCategory: "tabs") != nil)
        let reported = try Self.object(try catalog.categories()["tabs"])
        #expect(reported["newerOption"] as? Int == 3)
        #expect(reported["enablePreviewTabs"] as? Bool == false)
    }

    @Test("A pulled deletion of a theme a newer build wrote moves its file to the Trash")
    func pulledDeletionRemovesANewerThemeFile() throws {
        let harness = try Harness()
        let themes = harness.root.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let file = themes.appendingPathComponent("user.newer.json")
        try Data(#"{"appearance":"dark","id":"user.newer","name":"Newer","schema":99}"#.utf8).write(to: file)
        harness.themes.reloadSynchronously()
        let category = ThemeCatalog.syncCategory(for: "user.newer")

        try harness.catalog().apply(category, document: nil)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try harness.stores.documents()[category] == nil)
    }
}
