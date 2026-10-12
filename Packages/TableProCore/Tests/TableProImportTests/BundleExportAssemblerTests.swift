import Foundation
import TableProImport
import Testing

@Suite("Export carries only what the exported connections use")
struct BundleExportAssemblerTests {
    private static let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static let ordersId = UUID()
    private static let cacheId = UUID()
    private static let otherId = UUID()
    private static let clientGroupId = UUID()
    private static let productionGroupId = UUID()
    private static let prodTagId = UUID()
    private static let unusedTagId = UUID()
    private static let readerProfileId = UUID()
    private static let unusedProfileId = UUID()
    private static let reportsFolderId = UUID()
    private static let dailyFolderId = UUID()
    private static let sharedFolderId = UUID()
    private static let otherFolderId = UUID()
    private static let nestedFolderId = UUID()

    private static let password = ExportableCredentials(
        password: "hunter2", sshPassword: nil, keyPassphrase: nil,
        sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
    )

    @Test("Connections get refs c1, c2 in input order with their settings")
    func connectionRefsFollowInputOrder() throws {
        let bundle = try Self.assemble(.connectionsOnly)

        #expect(bundle.connections.map(\.ref) == ["c1", "c2"])
        #expect(bundle.connections.map(\.settings.name) == ["Orders", "Cache"])
        #expect(bundle.exportedAt == Self.exportedAt)
        #expect(bundle.appVersion == "0.70.0")
    }

    @Test("A connection's whole group chain travels with its colors")
    func groupChainTravels() throws {
        let bundle = try Self.assemble(.connectionsOnly)

        let chain = bundle.groupChain(bundle.connection("c1")?.groupRef)
        #expect(chain.map(\.name) == ["Client A", "Production"])
        #expect(chain.map(\.color) == ["Blue", nil])
        #expect(bundle.connection("c2")?.groupRef == nil)
    }

    @Test("Only the tags and profiles exported connections use travel")
    func onlyUsedTagsAndProfilesTravel() throws {
        let bundle = try Self.assemble(.connectionsOnly)

        #expect(bundle.tags == [BundleTag(name: "prod", color: "Red")])
        #expect(bundle.connection("c1")?.tagNames == ["prod"])
        #expect(bundle.credentialProfiles.map(\.name) == ["reader"])
        #expect(bundle.credentialProfile(bundle.connection("c1")?.credentialProfileRef)?.passwordMode == .pgpass)
    }

    @Test("Credentials travel only when asked for")
    func credentialsOnlyOnRequest() throws {
        let withheld = try Self.assemble(BundleExportOptions())
        let included = try Self.assemble(BundleExportOptions(includesCredentials: true))

        #expect(withheld.credentials.isEmpty)
        #expect(included.credentials == ["c1": Self.password])
    }

    @Test("By default only queries scoped to an exported connection travel")
    func exactScopeFilter() throws {
        let bundle = try Self.assemble(BundleExportOptions())

        #expect(bundle.savedQueries.map(\.name) == ["Daily users", "Hit rate", "Mixed chain"])
        #expect(bundle.savedQueries.map(\.connectionRef) == ["c1", "c2", "c1"])
    }

    @Test("Global queries travel only with the global option")
    func globalQueriesWithTheOption() throws {
        let bundle = try Self.assemble(BundleExportOptions(includesGlobalSavedQueries: true))

        let global = bundle.savedQueries.filter { $0.connectionRef == nil }
        #expect(global.map(\.name) == ["Server time"])
        #expect(bundle.folderChain(global.first?.folderRef).map(\.name) == ["Shared"])
    }

    @Test("Connections only carries no queries and no folders")
    func connectionsOnlyCarriesNoQueries() throws {
        let bundle = try Self.assemble(BundleExportOptions(includesSavedQueries: false, includesGlobalSavedQueries: true))

        #expect(bundle.savedQueries.isEmpty)
        #expect(bundle.queryFolders.isEmpty)
        #expect(BundleExportOptions.connectionsOnly == BundleExportOptions(includesSavedQueries: false))
    }

    @Test("A query keeps its folder chain while every folder in it can travel")
    func folderChainTravels() throws {
        let bundle = try Self.assemble(BundleExportOptions())

        let daily = try #require(bundle.savedQueries.first(where: { $0.name == "Daily users" }))
        let chain = bundle.folderChain(daily.folderRef)
        #expect(chain.map(\.name) == ["Reports", "Daily"])
        #expect(chain.map(\.connectionRef) == ["c1", "c1"])
    }

    @Test("A folder chain is cut at the first folder of a connection that is not exported")
    func folderChainIsCut() throws {
        let bundle = try Self.assemble(BundleExportOptions())

        let mixed = try #require(bundle.savedQueries.first(where: { $0.name == "Mixed chain" }))
        #expect(bundle.folderChain(mixed.folderRef).map(\.name) == ["Shared"])
        #expect(!bundle.queryFolders.contains(where: { $0.name == "Other" || $0.name == "Nested" }))
    }

    @Test("The same input gives the same bundle")
    func refsAreDeterministic() throws {
        let options = BundleExportOptions(includesGlobalSavedQueries: true)

        let first = try Self.assemble(options)
        let second = try Self.assemble(options)

        #expect(first == second)
        #expect(first.queryFolders.map(\.ref) == ["f1", "f2", "f3"])
        #expect(first.savedQueries.map(\.ref) == ["q1", "q2", "q3", "q4"])
    }

    @Test("A group parent cycle in the library ends the chain instead of looping")
    func groupCycleEnds() throws {
        let first = UUID()
        let second = UUID()
        let input = BundleExportInput(
            connections: [BundleExportInput.Connection(id: Self.ordersId, settings: Self.settings("Orders"), groupId: first)],
            groups: [
                BundleExportInput.Group(id: first, name: "First", parentId: second),
                BundleExportInput.Group(id: second, name: "Second", parentId: first)
            ]
        )

        let bundle = try BundleExportAssembler.assemble(input, options: .connectionsOnly, appVersion: "0.70.0")

        #expect(bundle.groupChain(bundle.connection("c1")?.groupRef).map(\.name) == ["Second", "First"])
    }

    @Test("Counts split connection-scoped and global queries and skip other connections")
    func savedQueryCounts() {
        let counts = BundleExportAssembler.savedQueryCounts(Self.input())

        #expect(counts == SavedQueryCounts(connectionScoped: 3, global: 1))
    }

    private static func assemble(_ options: BundleExportOptions) throws -> ConnectionBundle {
        try BundleExportAssembler.assemble(input(), options: options, appVersion: "0.70.0", exportedAt: exportedAt)
    }

    private static func settings(_ name: String) -> ExportableConnection {
        ExportableConnection(name: name, host: name.lowercased(), port: 5_432, database: "d", username: "u", type: "PostgreSQL")
    }

    private static func input() -> BundleExportInput {
        BundleExportInput(
            connections: [
                BundleExportInput.Connection(
                    id: ordersId,
                    settings: settings("Orders"),
                    groupId: productionGroupId,
                    tagIds: [prodTagId, UUID()],
                    credentialProfileId: readerProfileId,
                    credentials: password
                ),
                BundleExportInput.Connection(id: cacheId, settings: settings("Cache"))
            ],
            groups: [
                BundleExportInput.Group(id: clientGroupId, name: "Client A", color: "Blue"),
                BundleExportInput.Group(id: productionGroupId, name: "Production", parentId: clientGroupId)
            ],
            tags: [
                BundleExportInput.Tag(id: prodTagId, name: "prod", color: "Red"),
                BundleExportInput.Tag(id: unusedTagId, name: "unused", color: "Gray")
            ],
            credentialProfiles: [
                BundleExportInput.CredentialProfile(id: readerProfileId, name: "reader", username: "ro", passwordMode: .pgpass),
                BundleExportInput.CredentialProfile(id: unusedProfileId, name: "unused", username: "x", passwordMode: .stored)
            ],
            queryFolders: [
                BundleExportInput.QueryFolder(id: reportsFolderId, name: "Reports", connectionId: ordersId),
                BundleExportInput.QueryFolder(id: dailyFolderId, name: "Daily", parentId: reportsFolderId, connectionId: ordersId),
                BundleExportInput.QueryFolder(id: sharedFolderId, name: "Shared"),
                BundleExportInput.QueryFolder(id: otherFolderId, name: "Other", parentId: sharedFolderId, connectionId: otherId),
                BundleExportInput.QueryFolder(id: nestedFolderId, name: "Nested", parentId: otherFolderId, connectionId: ordersId)
            ],
            savedQueries: [
                BundleExportInput.SavedQuery(
                    id: UUID(), name: "Daily users", sql: "SELECT 1", keyword: "dau",
                    folderId: dailyFolderId, connectionId: ordersId
                ),
                BundleExportInput.SavedQuery(id: UUID(), name: "Hit rate", sql: "INFO stats", connectionId: cacheId),
                BundleExportInput.SavedQuery(id: UUID(), name: "Not exported", sql: "SELECT 2", connectionId: otherId),
                BundleExportInput.SavedQuery(id: UUID(), name: "Server time", sql: "SELECT now()", folderId: sharedFolderId),
                BundleExportInput.SavedQuery(
                    id: UUID(), name: "Mixed chain", sql: "SELECT 3",
                    folderId: nestedFolderId, connectionId: ordersId
                )
            ]
        )
    }
}
