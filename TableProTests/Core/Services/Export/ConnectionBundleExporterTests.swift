//
//  ConnectionBundleExporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct ConnectionBundleExporterTests {
    private static let queriesOnly = BundleExportOptions(includesSavedQueries: true)
    private static let queriesAndGlobals = BundleExportOptions(includesSavedQueries: true, includesGlobalSavedQueries: true)

    private func makeConnection(name: String = "Dev") -> DatabaseConnection {
        DatabaseConnection(
            name: name, host: "db.example.com", port: 5_432,
            database: "app", username: "admin", type: .postgresql
        )
    }

    private func seedQueries(in library: ImportLibraryFixture, exported: UUID, other: UUID) async {
        let reports = SQLFavoriteFolder(name: "Reports", connectionId: exported)
        _ = await library.favorites.addFolder(reports)
        _ = await library.favorites.addFavorite(
            SQLFavorite(name: "Daily", query: "select 1", keyword: "dau", folderId: reports.id, connectionId: exported)
        )
        _ = await library.favorites.addFavorite(SQLFavorite(name: "Locks", query: "select 2"))
        _ = await library.favorites.addFavorite(SQLFavorite(name: "Elsewhere", query: "select 3", connectionId: other))
    }

    // MARK: - Files

    @Test("A plain file round-trips connections through the codec and carries no credentials")
    func plainRoundTrip() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let connections = [makeConnection(name: "Primary"), makeConnection(name: "Replica")]
        #expect(library.connections.savePassword("hunter2", for: connections[0].id))

        let data = try await library.exporter.fileData(for: connections, options: .connectionsOnly, passphrase: nil)

        let bundle = try ConnectionBundleCodec.decode(data)
        #expect(bundle.connections.map(\.settings.name) == ["Primary", "Replica"])
        #expect(bundle.credentials.isEmpty)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("hunter2"))
    }

    @Test("A connection's icon survives a file export and its import")
    func iconRoundTrip() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var connection = makeConnection(name: "Primary")
        connection.iconName = "server.rack"

        let data = try await library.exporter.fileData(for: [connection], options: .connectionsOnly, passphrase: nil)
        let exported = try #require(try ConnectionBundleCodec.decode(data).connections.first).settings
        let imported = DatabaseConnection(
            importing: exported,
            id: UUID(),
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { _ in false }
        )

        #expect(exported.iconName == "server.rack")
        #expect(imported.iconName == "server.rack")
    }

    @Test("An encrypted file decrypts with the right passphrase and carries the password")
    func encryptedRoundTrip() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let secret = makeConnection(name: "Secret")
        #expect(library.connections.savePassword("hunter2", for: secret.id))

        let data = try await library.exporter.fileData(
            for: [secret],
            options: BundleExportOptions(includesCredentials: true, includesSavedQueries: false),
            passphrase: "correct horse"
        )

        #expect(ConnectionBundleCodec.isEncrypted(data))
        let bundle = try await ConnectionBundleCodec.decode(data, passphrase: "correct horse")
        #expect(bundle.connections.map(\.settings.name) == ["Secret"])
        #expect(bundle.credentials["c1"]?.password == "hunter2")
    }

    @Test("An encrypted file does not open with the wrong passphrase")
    func encryptedWrongPassphrase() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let data = try await library.exporter.fileData(
            for: [makeConnection()],
            options: .connectionsOnly,
            passphrase: "right-one"
        )

        await #expect(throws: (any Error).self) {
            _ = try await ConnectionBundleCodec.decode(data, passphrase: "wrong-one")
        }
    }

    @Test("Credentials without a passphrase are refused")
    func credentialsNeedAPassphrase() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }

        let exporter = library.exporter
        let connection = makeConnection()

        await #expect(throws: ConnectionBundleError.credentialsRequireEncryption) {
            _ = try await exporter.fileData(
                for: [connection],
                options: BundleExportOptions(includesCredentials: true),
                passphrase: nil
            )
        }
    }

    // MARK: - Saved queries

    @Test("Saved queries travel only with the option, and only those of the exported connections")
    func savedQueriesFollowTheOption() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let exported = makeConnection(name: "Orders")
        await seedQueries(in: library, exported: exported.id, other: UUID())

        let exporter = library.exporter
        let withoutData = try await exporter.fileData(for: [exported], options: .connectionsOnly, passphrase: nil)
        let scopedData = try await exporter.fileData(for: [exported], options: Self.queriesOnly, passphrase: nil)
        let globalsData = try await exporter.fileData(for: [exported], options: Self.queriesAndGlobals, passphrase: nil)
        let without = try ConnectionBundleCodec.decode(withoutData)
        let scoped = try ConnectionBundleCodec.decode(scopedData)
        let withGlobals = try ConnectionBundleCodec.decode(globalsData)

        #expect(without.savedQueries.isEmpty)
        #expect(without.queryFolders.isEmpty)
        let daily = try #require(scoped.savedQueries.first)
        #expect(scoped.savedQueries.count == 1)
        #expect(daily.name == "Daily")
        #expect(daily.keyword == "dau")
        #expect(daily.connectionRef == BundleRef("c1"))
        #expect(scoped.folderChain(daily.folderRef).map(\.name) == ["Reports"])
        #expect(Set(withGlobals.savedQueries.map(\.name)) == ["Daily", "Locks"])
    }

    @Test("Counts split the exported connections' saved queries from global ones")
    func savedQueryCounts() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let exported = makeConnection(name: "Orders")
        await seedQueries(in: library, exported: exported.id, other: UUID())

        let counts = await library.exporter.savedQueryCounts(for: [exported])

        #expect(counts == SavedQueryCounts(connectionScoped: 1, global: 1))
    }

    @Test("Unreadable saved queries refuse an export that asked for them")
    func unreadableQueriesRefuseTheExport() async throws {
        let library = try ImportLibraryFixture(damage: [.favorites])
        defer { library.cleanUp() }

        let exporter = library.exporter
        let connection = makeConnection()
        let options = Self.queriesOnly

        #expect(await exporter.savedQueryCounts(for: [connection]) == nil)

        await #expect(throws: ConnectionBundleExportError.savedQueriesUnreadable) {
            _ = try await exporter.fileData(for: [connection], options: options, passphrase: nil)
        }
        let plain = try await exporter.fileData(for: [connection], options: .connectionsOnly, passphrase: nil)
        #expect(try ConnectionBundleCodec.decode(plain).connections.count == 1)
    }

    @Test("The Team Catalog bundle never carries saved queries or credentials")
    func connectionsOnlyBundleCarriesNoQueries() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let exported = makeConnection(name: "Orders")
        #expect(library.connections.savePassword("hunter2", for: exported.id))
        await seedQueries(in: library, exported: exported.id, other: UUID())

        let bundle = try library.exporter.connectionsOnlyBundle(for: [exported])

        #expect(bundle.connections.map(\.settings.name) == ["Orders"])
        #expect(bundle.savedQueries.isEmpty)
        #expect(bundle.queryFolders.isEmpty)
        #expect(bundle.credentials.isEmpty)
    }

    // MARK: - Library structure

    @Test("A nested group exports as its whole chain, root first, with colors and icons")
    func groupChainExportsRootFirst() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let client = ConnectionGroup(name: "Client A", color: .blue, iconName: "briefcase")
        let production = ConnectionGroup(name: "Production", parentId: client.id)
        try library.groups.addGroup(client)
        try library.groups.addGroup(production)
        var connection = makeConnection(name: "Orders")
        connection.groupId = production.id

        let bundle = try library.exporter.connectionsOnlyBundle(for: [connection])

        let chain = bundle.groupChain(bundle.connections.first?.groupRef)
        #expect(chain.map(\.name) == ["Client A", "Production"])
        #expect(chain.first?.color == ConnectionColor.blue.rawValue)
        #expect(chain.map(\.iconName) == ["briefcase", nil])
        #expect(library.exporter.groupPath(for: connection) == ["Client A", "Production"])
    }
}

struct ConnectionExportPassphraseStateTests {
    @Test("empty passphrase is not exportable")
    func testEmpty() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "", confirmation: "")
        #expect(state == .empty)
        #expect(!state.allowsExport)
    }

    @Test("passphrase under the minimum length is too short")
    func testTooShort() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "1234567", confirmation: "1234567")
        #expect(state == .tooShort)
        #expect(!state.allowsExport)
    }

    @Test("valid passphrase with empty confirmation is incomplete")
    func testIncomplete() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "longenough", confirmation: "")
        #expect(state == .incomplete)
        #expect(!state.allowsExport)
    }

    @Test("non-matching confirmation is a mismatch")
    func testMismatch() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "longenough", confirmation: "different1")
        #expect(state == .mismatch)
        #expect(!state.allowsExport)
    }

    @Test("matching passphrase at the minimum length is exportable")
    func testOk() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "12345678", confirmation: "12345678")
        #expect(state == .ok)
        #expect(state.allowsExport)
    }
}
