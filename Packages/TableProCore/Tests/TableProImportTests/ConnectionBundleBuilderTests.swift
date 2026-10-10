import Foundation
@testable import TableProImport
import Testing

@Suite("The builder turns paths into ref trees")
struct ConnectionBundleBuilderTests {
    private typealias Group = ConnectionBundleBuilder.GroupComponent
    private typealias Folder = ConnectionBundleBuilder.FolderComponent

    @Test("Connections keep their order, refs and settings")
    func connectionsKeepOrder() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("B"), ref: "b")
        builder.addConnection(Self.settings("A"), ref: "a")

        let bundle = try builder.build()

        #expect(bundle.connections.map(\.ref) == ["b", "a"])
        #expect(bundle.connections.map(\.settings.name) == ["B", "A"])
        #expect(bundle.exportedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(bundle.appVersion == "0.70.0")
    }

    @Test("A group path becomes a chain of groups, root first")
    func groupPathBecomesChain() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", groupPath: [Group(name: "Client A", color: "Blue"), Group(name: "Production")])

        let bundle = try builder.build()

        #expect(bundle.groups == [
            BundleGroup(ref: "g1", name: "Client A", color: "Blue"),
            BundleGroup(ref: "g2", name: "Production", parentRef: "g1")
        ])
        #expect(bundle.connection("a")?.groupRef == "g2")
    }

    @Test("The same path in another case or with padding reuses its groups")
    func samePathReusesGroups() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", groupPath: [Group(name: "Client A"), Group(name: "Production")])
        builder.addConnection(Self.settings("B"), ref: "b", groupPath: [Group(name: " client a "), Group(name: "PRODUCTION")])
        builder.addConnection(Self.settings("C"), ref: "c", groupPath: [Group(name: "Client A")])

        let bundle = try builder.build()

        #expect(bundle.groups.count == 2)
        #expect(bundle.connection("b")?.groupRef == bundle.connection("a")?.groupRef)
        #expect(bundle.connection("c")?.groupRef == "g1")
    }

    @Test("Groups with one name under different parents stay distinct")
    func sameNameUnderDifferentParentsStaysDistinct() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", groupPath: [Group(name: "A"), Group(name: "Prod")])
        builder.addConnection(Self.settings("B"), ref: "b", groupPath: [Group(name: "B"), Group(name: "Prod")])

        let bundle = try builder.build()

        let first = bundle.groupChain(bundle.connection("a")?.groupRef).map(\.name)
        let second = bundle.groupChain(bundle.connection("b")?.groupRef).map(\.name)
        #expect(first == ["A", "Prod"])
        #expect(second == ["B", "Prod"])
        #expect(bundle.connection("a")?.groupRef != bundle.connection("b")?.groupRef)
    }

    @Test("Empty path components are dropped and names are trimmed")
    func emptyComponentsAreDropped() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", groupPath: [Group(name: ""), Group(name: " Work "), Group(name: "  ")])
        builder.addConnection(Self.settings("B"), ref: "b", groupPath: [Group(name: " ")])

        let bundle = try builder.build()

        #expect(bundle.groups == [BundleGroup(ref: "g1", name: "Work")])
        #expect(bundle.connection("a")?.groupRef == "g1")
        #expect(bundle.connection("b")?.groupRef == nil)
    }

    @Test("The first color given for a group wins")
    func firstGroupColorWins() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", groupPath: [Group(name: "Uncolored")])
        builder.addConnection(Self.settings("B"), ref: "b", groupPath: [Group(name: "uncolored", color: "Blue")])
        builder.addConnection(Self.settings("C"), ref: "c", groupPath: [Group(name: "Red", color: "Red")])
        builder.addConnection(Self.settings("D"), ref: "d", groupPath: [Group(name: "red", color: "Green")])

        let bundle = try builder.build()

        #expect(bundle.groups.map(\.color) == ["Blue", "Red"])
    }

    @Test("Tags are unique by name, keep the first spelling and the first color")
    func tagsAreUniqueByName() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", tags: [BundleTag(name: "Prod"), BundleTag(name: "prod", color: "Red")])
        builder.addConnection(Self.settings("B"), ref: "b", tags: [BundleTag(name: " PROD ", color: "Blue"), BundleTag(name: ""), BundleTag(name: "eu")])

        let bundle = try builder.build()

        #expect(bundle.tags == [BundleTag(name: "Prod", color: "Red"), BundleTag(name: "eu")])
        #expect(bundle.connection("a")?.tagNames == ["Prod"])
        #expect(bundle.connection("b")?.tagNames == ["Prod", "eu"])
    }

    @Test("Profiles are unique by name and get refs in order")
    func profilesAreUniqueByName() throws {
        let reader = ConnectionBundleBuilder.ProfileSpec(name: "Reader", username: "ro", passwordMode: .pgpass, secureFieldIds: ["token"])
        let writer = ConnectionBundleBuilder.ProfileSpec(name: "writer", username: "rw", passwordMode: .prompt)
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", credentialProfile: reader)
        builder.addConnection(Self.settings("B"), ref: "b", credentialProfile: writer)
        builder.addConnection(
            Self.settings("C"),
            ref: "c",
            credentialProfile: ConnectionBundleBuilder.ProfileSpec(name: "READER", username: "other", passwordMode: .stored)
        )

        let bundle = try builder.build()

        #expect(bundle.credentialProfiles == [
            BundleCredentialProfile(ref: "p1", name: "Reader", username: "ro", passwordMode: .pgpass, secureFieldIds: ["token"]),
            BundleCredentialProfile(ref: "p2", name: "writer", username: "rw", passwordMode: .prompt)
        ])
        #expect(bundle.connection("c")?.credentialProfileRef == "p1")
    }

    @Test("Credentials are keyed by connection ref; empty ones are left out")
    func credentialsAreKeyedByRef() throws {
        let filled = ExportableCredentials(
            password: "pw", sshPassword: nil, keyPassphrase: nil,
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
        )
        let empty = ExportableCredentials(
            password: nil, sshPassword: nil, keyPassphrase: nil,
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: [:]
        )
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a", credentials: filled)
        builder.addConnection(Self.settings("B"), ref: "b", credentials: empty)

        let bundle = try builder.build()

        #expect(bundle.credentials == ["a": filled])
    }

    @Test("A repeated connection ref makes build throw")
    func repeatedConnectionRefThrows() {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a")
        builder.addConnection(Self.settings("B"), ref: "a")

        #expect(throws: ConnectionBundleError.invalidBundle(BundleViolation.repeatedRef("a").message)) {
            _ = try builder.build()
        }
    }

    @Test("Folder paths are matched by name and connection")
    func folderPathsMatchByNameAndConnection() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a")
        builder.addConnection(Self.settings("B"), ref: "b")
        let daily = builder.addSavedQuery(
            name: "Daily", sql: "SELECT 1", keyword: "dau",
            folderPath: [Folder(name: "Reports", connection: "a"), Folder(name: "Daily", connection: "a")],
            connection: "a"
        )
        let weekly = builder.addSavedQuery(
            name: "Weekly", sql: "SELECT 2", keyword: nil,
            folderPath: [Folder(name: "reports ", connection: "a")],
            connection: "a"
        )
        let other = builder.addSavedQuery(
            name: "Other", sql: "SELECT 3", keyword: nil,
            folderPath: [Folder(name: "Reports", connection: "b")],
            connection: "b"
        )
        let global = builder.addSavedQuery(
            name: "Global", sql: "SELECT 4", keyword: nil,
            folderPath: [Folder(name: "Reports")],
            connection: nil
        )

        let bundle = try builder.build()

        #expect(bundle.queryFolders == [
            BundleQueryFolder(ref: "f1", name: "Reports", connectionRef: "a"),
            BundleQueryFolder(ref: "f2", name: "Daily", parentRef: "f1", connectionRef: "a"),
            BundleQueryFolder(ref: "f3", name: "Reports", connectionRef: "b"),
            BundleQueryFolder(ref: "f4", name: "Reports")
        ])
        #expect([daily, weekly, other, global] == ["q1", "q2", "q3", "q4"])
        #expect(bundle.savedQueries.map(\.folderRef) == ["f2", "f1", "f3", "f4"])
        #expect(bundle.savedQueries.first == BundleSavedQuery(
            ref: "q1", name: "Daily", sql: "SELECT 1", keyword: "dau", folderRef: "f2", connectionRef: "a"
        ))
    }

    @Test("A query with no folder path sits at the root")
    func queryWithoutFolderSitsAtRoot() throws {
        var builder = Self.builder()
        builder.addSavedQuery(name: "Q", sql: "SELECT 1", keyword: nil, folderPath: [Folder(name: " ")], connection: nil)

        let bundle = try builder.build()

        #expect(bundle.queryFolders.isEmpty)
        #expect(bundle.savedQueries.first?.folderRef == nil)
    }

    @Test("A requested query ref is kept unless it is taken or empty")
    func requestedQueryRefs() throws {
        var builder = Self.builder()
        let explicit = builder.addSavedQuery(name: "A", sql: "SELECT 1", keyword: nil, connection: nil, ref: "q2")
        let minted = builder.addSavedQuery(name: "B", sql: "SELECT 2", keyword: nil, connection: nil)
        let skipped = builder.addSavedQuery(name: "C", sql: "SELECT 3", keyword: nil, connection: nil)
        let taken = builder.addSavedQuery(name: "D", sql: "SELECT 4", keyword: nil, connection: nil, ref: "q2")
        let blank = builder.addSavedQuery(name: "E", sql: "SELECT 5", keyword: nil, connection: nil, ref: " ")

        let bundle = try builder.build()

        #expect([explicit, minted, skipped, taken, blank] == ["q2", "q1", "q3", "q4", "q5"])
        #expect(bundle.savedQueries.map(\.ref) == ["q2", "q1", "q3", "q4", "q5"])
    }

    @Test("An oversized query takes a ref from the same namespace and adds nothing to the bundle")
    func oversizedQueryReservesARef() throws {
        var builder = Self.builder()
        builder.addConnection(Self.settings("A"), ref: "a")
        let first = builder.addSavedQuery(name: "Small", sql: "SELECT 1", keyword: nil, connection: "a", ref: "dump")
        let oversized = builder.addOversizedSavedQuery(
            name: "Huge",
            byteCount: 2_000_000,
            folderPath: [Folder(name: " Dumps ", connection: "a"), Folder(name: "")],
            connection: "a",
            ref: "dump"
        )
        let next = builder.addSavedQuery(name: "Next", sql: "SELECT 2", keyword: nil, connection: "a")

        let bundle = try builder.build()

        #expect(first == "dump")
        #expect(oversized == OversizedSavedQuery(ref: "q1", name: "Huge", folderPath: ["Dumps"], connection: "a", byteCount: 2_000_000))
        #expect(next == "q2")
        #expect(bundle.savedQueries.map(\.ref) == ["dump", "q2"])
        #expect(bundle.queryFolders.isEmpty)
    }

    @Test("A query or folder bound to a connection the builder never saw fails to build")
    func unknownConnectionFailsToBuild() {
        var builder = Self.builder()
        builder.addSavedQuery(name: "Q", sql: "SELECT 1", keyword: nil, connection: "ghost")

        #expect(throws: ConnectionBundleError.invalidBundle(BundleViolation.unresolvedRef("ghost", referrer: "q1").message)) {
            _ = try builder.build()
        }
    }

    private static func builder() -> ConnectionBundleBuilder {
        ConnectionBundleBuilder(appVersion: "0.70.0", exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func settings(_ name: String) -> ExportableConnection {
        ExportableConnection(name: name, host: name.lowercased(), port: 5_432, database: "d", username: "u", type: "PostgreSQL")
    }
}
