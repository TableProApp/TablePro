//
//  ConnectionEditorStoreSecretStateTests.swift
//  TableProTests
//

import Foundation
import TableProSSHConfig
import Testing

@testable import TablePro

// Emptying a password field must delete the stored secret, or the next connect, an export and a duplicate still carry it.
@MainActor
struct ConnectionEditorStoreSecretStateTests {
    private final class ScriptedKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let result: KeychainStringResult

        init(_ result: KeychainStringResult) {
            self.result = result
        }

        @discardableResult
        func writeString(_ value: String, forKey key: String) -> Bool { true }

        func readStringResult(forKey key: String) -> KeychainStringResult {
            lock.withLock { result }
        }

        func delete(forKey key: String) {}
    }

    // The fixture's services over a library whose every Keychain read answers `result`.
    private func store(
        _ fixture: ConnectionEditorStoreFixture,
        keychain result: KeychainStringResult,
        connection: DatabaseConnection
    ) -> ConnectionEditorStore {
        let storage = ConnectionStorage(
            fileURL: fixture.directory.appendingPathComponent("scripted-connections.json"),
            userDefaults: fixture.suite.defaults,
            keychain: ScriptedKeychain(result)
        )
        #expect(storage.saveConnections([connection]))
        return ConnectionEditorStore(
            request: .edit(connectionId: connection.id),
            services: fixture.services.replacingConnectionStorage(storage),
            recentConnections: fixture.recents,
            listPreferences: fixture.listPreferences
        )
    }

    private func plan(_ store: ConnectionEditorStore) -> SecretWritePlan {
        ConnectionEditorEngine.secretPlan(store.draft, store.traits, originalTraits: store.originalTraits, store.context)
    }

    private func clearsPassword(_ store: ConnectionEditorStore) -> Bool {
        ConnectionEditorEngine.clearsStoredPassword(store.draft, store.traits)
    }

    private func sshConnection() -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        return connection
    }

    @Test("Clearing a password that was stored asks for the stored one to be deleted")
    func clearedPasswordIsDeleted() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .found("hunter2"), connection: TestFixtures.makeConnection())
        #expect(store.draft.credentials.password == "hunter2")
        store.update { $0.credentials.password = "" }

        #expect(clearsPassword(store))
        #expect(plan(store).deletesAfterRecord.contains(.password))
    }

    @Test("Leaving a loaded password in place deletes nothing")
    func untouchedPasswordIsKept() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .found("hunter2"), connection: TestFixtures.makeConnection())

        #expect(!clearsPassword(store))
        #expect(!plan(store).deletesAfterRecord.contains(.password))
    }

    @Test("An empty field on a connection that never had a password deletes nothing")
    func neverStoredDeletesNothing() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .notFound, connection: TestFixtures.makeConnection())
        store.update { $0.credentials.password = "" }

        #expect(!clearsPassword(store))
        #expect(!plan(store).deletesAfterRecord.contains(.password))
    }

    @Test(
        "A keychain that could not be read never causes a delete",
        arguments: [
            KeychainStringResult.locked,
            .userCancelled,
            .authFailed,
            .error(-25_300),
        ]
    )
    func unreadableKeychainNeverDeletes(_ result: KeychainStringResult) throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: result, connection: TestFixtures.makeConnection())
        store.update { $0.credentials.password = "" }

        #expect(!clearsPassword(store))
        let plan = plan(store)
        #expect(!plan.deletesAfterRecord.contains(.password))
        #expect(!plan.stagedDeletes.contains(.password))
    }

    @Test("Switching to prompt mode is handled by the prompt arm, not by the cleared arm")
    func promptModeIsNotACleared() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .found("hunter2"), connection: TestFixtures.makeConnection())
        store.update { $0.credentials.password = "" }
        store.setPasswordPrompt(true)

        #expect(!clearsPassword(store))
        #expect(ConnectionEditorEngine.effectivePromptForPassword(store.draft, store.traits))
        #expect(plan(store).deletesAfterRecord.contains(.password))
    }

    @Test("An emptied inline SSH password and passphrase are deleted too")
    func clearedInlineSSHSecretsAreDeleted() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .found("secret"), connection: sshConnection())
        store.update {
            $0.ssh.password = ""
            $0.ssh.keyPassphrase = ""
        }

        #expect(store.draft.ssh.clearsStoredPassword)
        #expect(store.draft.ssh.clearsStoredKeyPassphrase)
        let plan = plan(store)
        #expect(plan.deletesAfterRecord.contains(.sshPassword))
        #expect(plan.deletesAfterRecord.contains(.sshKeyPassphrase))
    }

    @Test("An inline SSH secret that could not be read is never deleted")
    func unreadableInlineSSHSecretsAreKept() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = store(fixture, keychain: .locked, connection: sshConnection())
        store.update {
            $0.ssh.password = ""
            $0.ssh.keyPassphrase = ""
        }

        #expect(!store.draft.ssh.clearsStoredPassword)
        #expect(!store.draft.ssh.clearsStoredKeyPassphrase)
        let plan = plan(store)
        #expect(!plan.deletesAfterRecord.contains(.sshPassword))
        #expect(!plan.deletesAfterRecord.contains(.sshKeyPassphrase))
    }
}

@MainActor
private extension AppServices {
    func replacingConnectionStorage(_ storage: ConnectionStorage) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: storage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
