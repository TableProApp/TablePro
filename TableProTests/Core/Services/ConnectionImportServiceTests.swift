import Foundation
import TableProImport
import Testing

@testable import TablePro

@Suite("Connection Import Service")
@MainActor
struct ConnectionImportServiceTests {
    @Test("duplicate matching uses host port database and username case-insensitively")
    func duplicateMatchingUsesConnectionDetails() {
        let existing = DatabaseConnection(
            name: "Local Postgres",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: .postgresql
        )
        let imported = ExportableConnection(
            name: "Different Name",
            host: " db.example.com ",
            port: 5_432,
            database: " app ",
            username: " ADMIN ",
            type: "MySQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let preview = ConnectionExportService.analyzeImport(
            makeEnvelope(with: [imported]),
            existingConnections: [existing],
            registeredTypeIds: Set(["MySQL", "PostgreSQL"]),
            fileExists: { _ in true }
        )

        guard case .duplicate(let matchedId, _) = preview.items.first?.status else {
            Issue.record("Expected duplicate status")
            return
        }

        #expect(matchedId == existing.id)
    }

    @Test("different username on same host is not a duplicate")
    func differentUsernameSameHostIsNotADuplicate() {
        let existing = DatabaseConnection(
            name: "Local Postgres",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: .postgresql
        )
        let imported = ExportableConnection(
            name: "Local Postgres",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "readonly",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let preview = ConnectionExportService.analyzeImport(
            makeEnvelope(with: [imported]),
            existingConnections: [existing],
            registeredTypeIds: Set(["PostgreSQL"]),
            fileExists: { _ in true }
        )

        guard let item = preview.items.first else {
            Issue.record("Expected preview item")
            return
        }

        if case .duplicate = item.status {
            Issue.record("Expected non-duplicate status")
        }
    }

    @Test("redis connections with different database indices are not duplicates")
    func redisConnectionsWithDifferentDatabaseIndicesAreNotDuplicates() {
        let existing = DatabaseConnection(
            name: "Redis DB 0",
            host: "redis.example.com",
            port: 6_379,
            username: "cache",
            type: .redis,
            redisDatabase: 0
        )
        let imported = ExportableConnection(
            name: "Redis DB 1",
            host: "redis.example.com",
            port: 6_379,
            database: "",
            username: "cache",
            type: "Redis",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: 1,
            startupCommands: nil,
            localOnly: nil
        )

        let preview = ConnectionExportService.analyzeImport(
            makeEnvelope(with: [imported]),
            existingConnections: [existing],
            registeredTypeIds: Set(["Redis"]),
            fileExists: { _ in true }
        )

        guard let item = preview.items.first else {
            Issue.record("Expected preview item")
            return
        }

        if case .duplicate = item.status {
            Issue.record("Expected non-duplicate status for different Redis database indices")
        }
    }

    @Test("redis connections with matching database indices are duplicates")
    func redisConnectionsWithMatchingDatabaseIndicesAreDuplicates() {
        let existing = DatabaseConnection(
            name: "Redis DB 0",
            host: "redis.example.com",
            port: 6_379,
            username: "cache",
            type: .redis,
            redisDatabase: 0
        )
        let imported = ExportableConnection(
            name: "Redis DB 0 Copy",
            host: "redis.example.com",
            port: 6_379,
            database: "",
            username: "cache",
            type: "Redis",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: 0,
            startupCommands: nil,
            localOnly: nil
        )

        let preview = ConnectionExportService.analyzeImport(
            makeEnvelope(with: [imported]),
            existingConnections: [existing],
            registeredTypeIds: Set(["Redis"]),
            fileExists: { _ in true }
        )

        guard case .duplicate(let matchedId, _) = preview.items.first?.status else {
            Issue.record("Expected duplicate status for matching Redis database indices")
            return
        }

        #expect(matchedId == existing.id)
    }

    @Test("replace updates the existing connection")
    func replaceUpdatesTheExistingConnection() {
        let storage = makeStorage()
        let existing = DatabaseConnection(name: "Existing", host: "old.example.com", port: 5_432, type: .postgresql)
        storage.addConnection(existing)

        let imported = ExportableConnection(
            name: "Imported",
            host: "new.example.com",
            port: 5_433,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let (preview, item) = makeDuplicatePreview(imported: imported, existing: existing)
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .replace(existingId: existing.id)],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )
        let result = ConnectionExportService.performPreparedImport(
            prepared,
            connectionStorage: storage,
            notifyConnectionsChanged: {}
        )

        let saved = storage.loadConnections()
        let replacedId = result.connectionIdMap[0]
        #expect(result.importedCount == 1)
        #expect(replacedId == .some(existing.id))
        #expect(saved.count == 1)
        #expect(saved[0].id == existing.id)
        #expect(saved[0].name == "Imported")
        #expect(saved[0].host == "new.example.com")
        #expect(saved[0].port == 5_433)
        #expect(saved[0].database == "app")
        #expect(saved[0].username == "admin")
    }

    @Test("replace is excluded from newConnectionIdMap so its credentials are not restored")
    func replaceIsExcludedFromNewConnectionIdMap() {
        let existing = DatabaseConnection(name: "Existing", host: "db.example.com", port: 5_432, type: .postgresql)
        let imported = ExportableConnection(
            name: "Imported",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let (preview, item) = makeDuplicatePreview(imported: imported, existing: existing)
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .replace(existingId: existing.id)],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )

        #expect(prepared.connectionIdMap[0] == .some(existing.id))
        #expect(prepared.newConnectionIdMap.isEmpty)
    }

    @Test("added connections appear in newConnectionIdMap")
    func addedConnectionsAppearInNewConnectionIdMap() {
        let imported = ExportableConnection(
            name: "Fresh",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let item = ImportItem(connection: imported, status: .ready)
        let preview = ConnectionImportPreview(envelope: makeEnvelope(with: [imported]), items: [item])
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .importNew],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )

        #expect(prepared.newConnectionIdMap[0] != nil)
        #expect(prepared.newConnectionIdMap[0] == prepared.connectionIdMap[0])
    }

    @Test("as copy imports a renamed duplicate")
    func asCopyImportsARenamedDuplicate() {
        let storage = makeStorage()
        let existing = DatabaseConnection(name: "Existing", host: "db.example.com", port: 5_432, type: .postgresql)
        storage.addConnection(existing)

        let imported = ExportableConnection(
            name: "Imported",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let (preview, item) = makeDuplicatePreview(imported: imported, existing: existing)
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .importAsCopy],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )
        let result = ConnectionExportService.performPreparedImport(
            prepared,
            connectionStorage: storage,
            notifyConnectionsChanged: {}
        )

        let saved = storage.loadConnections()
        let importedId = result.connectionIdMap[0]
        #expect(result.importedCount == 1)
        #expect(importedId != nil)
        #expect(importedId != .some(existing.id))
        #expect(saved.count == 2)
        #expect(saved.contains { $0.id == existing.id && $0.name == "Existing" })
        if let importedId {
            #expect(saved.contains { $0.id == importedId && $0.name == "Imported (Imported)" })
        } else {
            Issue.record("Expected imported connection id")
        }
    }

    @Test("as copy resolves name collisions with a numeric suffix")
    func asCopyResolvesNameCollisions() {
        let imported = ExportableConnection(
            name: "Imported",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let existing = DatabaseConnection(name: "Imported", host: "db.example.com", port: 5_432, type: .postgresql)
        let (preview, item) = makeDuplicatePreview(imported: imported, existing: existing)
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .importAsCopy],
            existingNames: ["Imported", "Imported (Imported)", "Imported (Imported 2)"],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )

        guard case .add(let connection) = prepared.operations.first else {
            Issue.record("Expected an add operation")
            return
        }
        #expect(connection.name == "Imported (Imported 3)")
    }

    @Test("skip leaves the existing connection untouched")
    func skipLeavesTheExistingConnectionUntouched() {
        let storage = makeStorage()
        let existing = DatabaseConnection(name: "Existing", host: "db.example.com", port: 5_432, type: .postgresql)
        storage.addConnection(existing)

        let imported = ExportableConnection(
            name: "Imported",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let (preview, item) = makeDuplicatePreview(imported: imported, existing: existing)
        let prepared = ConnectionExportService.prepareImport(
            preview,
            resolutions: [item.id: .skip],
            tagIdsByName: [:],
            groupIdsByName: [:]
        )
        let result = ConnectionExportService.performPreparedImport(
            prepared,
            connectionStorage: storage,
            notifyConnectionsChanged: {}
        )

        let saved = storage.loadConnections()
        #expect(result.importedCount == 0)
        #expect(result.connectionIdMap.isEmpty)
        #expect(saved.count == 1)
        #expect(saved[0] == existing)
    }

    @Test("decoding a shared blob drops preConnectScript but keeps benign fields")
    func decodingStripsPreConnectScript() throws {
        let imported = ExportableConnection(
            name: "Evil",
            host: "localhost",
            port: 3_306,
            database: "",
            username: "root",
            type: "MySQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: ["preConnectScript": "touch /tmp/pwned", "mongoAuthSource": "admin"],
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let data = try ConnectionExportService.encode(makeEnvelope(with: [imported]))
        let decoded = try ConnectionImportDecoder.decodeData(data)
        let fields = decoded.connections.first?.additionalFields

        #expect(fields?["preConnectScript"] == nil)
        #expect(fields?["mongoAuthSource"] == "admin")
    }

    private func makeStorage() -> ConnectionStorage {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connection-import-\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.ConnectionImport.Sync.\(unique)") else {
            fatalError("Expected sync defaults suite")
        }
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        guard let defaults = UserDefaults(suiteName: "com.TablePro.tests.ConnectionImport.\(unique)") else {
            fatalError("Expected defaults suite")
        }
        return ConnectionStorage(fileURL: fileURL, userDefaults: defaults, syncTracker: tracker)
    }

    private func makeDuplicatePreview(
        imported: ExportableConnection,
        existing: DatabaseConnection
    ) -> (ConnectionImportPreview, ImportItem) {
        let item = ImportItem(connection: imported, status: .duplicate(existingId: existing.id, existingName: existing.name))
        let preview = ConnectionImportPreview(
            envelope: makeEnvelope(with: [imported]),
            items: [item]
        )
        return (preview, item)
    }

    private func makeEnvelope(with connections: [ExportableConnection]) -> ConnectionExportEnvelope {
        ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "Tests",
            connections: connections,
            groups: nil,
            tags: nil,
            credentials: nil
        )
    }
}
