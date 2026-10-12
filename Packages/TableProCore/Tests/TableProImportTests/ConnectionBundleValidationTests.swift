import Foundation
@testable import TableProImport
import Testing

@Suite("A bundle refuses broken structure and names the ref")
struct ConnectionBundleValidationTests {
    @Test("A well-formed bundle builds")
    func wellFormedBundleBuilds() throws {
        let bundle = try ConnectionBundleCodecTests.fullBundle()

        #expect(bundle.connections.count == 2)
    }

    @Test("An empty ref is refused for every kind")
    func emptyRefIsRefused() {
        let empty = BundleViolation.emptyRef
        expectRefused(empty) { try Self.bundle(connections: [Self.connection(" ")]) }
        expectRefused(empty) { try Self.bundle(groups: [BundleGroup(ref: "", name: "G")]) }
        expectRefused(empty) { try Self.bundle(profiles: [Self.profile("")]) }
        expectRefused(empty) { try Self.bundle(folders: [BundleQueryFolder(ref: "", name: "F")]) }
        expectRefused(empty) { try Self.bundle(queries: [Self.query("")]) }
    }

    @Test("A ref repeated within one kind is refused")
    func repeatedRefIsRefused() {
        expectRefused(.repeatedRef("c1")) { try Self.bundle(connections: [Self.connection("c1"), Self.connection("c1")]) }
        expectRefused(.repeatedRef("g1")) {
            try Self.bundle(groups: [BundleGroup(ref: "g1", name: "A"), BundleGroup(ref: "g1", name: "B")])
        }
        expectRefused(.repeatedRef("p1")) { try Self.bundle(profiles: [Self.profile("p1"), Self.profile("p1")]) }
        expectRefused(.repeatedRef("f1")) {
            try Self.bundle(folders: [BundleQueryFolder(ref: "f1", name: "A"), BundleQueryFolder(ref: "f1", name: "B")])
        }
        expectRefused(.repeatedRef("q1")) { try Self.bundle(queries: [Self.query("q1"), Self.query("q1")]) }
    }

    @Test("The same ref in two kinds is allowed")
    func sameRefAcrossKindsIsAllowed() throws {
        let bundle = try Self.bundle(
            connections: [Self.connection("x")],
            groups: [BundleGroup(ref: "x", name: "G")],
            folders: [BundleQueryFolder(ref: "x", name: "F", connectionRef: "x")],
            queries: [BundleSavedQuery(ref: "x", name: "Q", sql: "SELECT 1", folderRef: "x", connectionRef: "x")]
        )

        #expect(bundle.savedQueries.count == 1)
    }

    @Test("A connection link that does not resolve is refused")
    func unresolvedConnectionLinksAreRefused() {
        expectRefused(.unresolvedRef("g9", referrer: "c1")) {
            try Self.bundle(connections: [BundleConnection(ref: "c1", settings: Self.settings, groupRef: "g9")])
        }
        expectRefused(.unresolvedRef("p9", referrer: "c1")) {
            try Self.bundle(connections: [BundleConnection(ref: "c1", settings: Self.settings, credentialProfileRef: "p9")])
        }
    }

    @Test("Credentials for a connection that is not in the bundle are refused")
    func orphanCredentialsAreRefused() {
        let credentials = ExportableCredentials(
            password: "pw", sshPassword: nil, keyPassphrase: nil,
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
        )

        expectRefused(.unresolvedCredentials("c9")) {
            try ConnectionBundle(appVersion: "1.0", connections: [Self.connection("c1")], credentials: ["c9": credentials])
        }
    }

    @Test("A parent that does not resolve is refused")
    func unresolvedParentsAreRefused() {
        expectRefused(.unresolvedRef("g9", referrer: "g1")) {
            try Self.bundle(groups: [BundleGroup(ref: "g1", name: "A", parentRef: "g9")])
        }
        expectRefused(.unresolvedRef("f9", referrer: "f1")) {
            try Self.bundle(folders: [BundleQueryFolder(ref: "f1", name: "A", parentRef: "f9")])
        }
    }

    @Test("A folder or query bound to a missing connection or folder is refused")
    func unresolvedQueryLinksAreRefused() {
        expectRefused(.unresolvedRef("c9", referrer: "f1")) {
            try Self.bundle(folders: [BundleQueryFolder(ref: "f1", name: "A", connectionRef: "c9")])
        }
        expectRefused(.unresolvedRef("f9", referrer: "q1")) {
            try Self.bundle(queries: [BundleSavedQuery(ref: "q1", name: "Q", sql: "SELECT 1", folderRef: "f9")])
        }
        expectRefused(.unresolvedRef("c9", referrer: "q1")) {
            try Self.bundle(queries: [BundleSavedQuery(ref: "q1", name: "Q", sql: "SELECT 1", connectionRef: "c9")])
        }
    }

    @Test("A parent cycle is refused, including a node that is its own parent")
    func cyclesAreRefused() {
        expectRefused(.cycle("g1")) {
            try Self.bundle(groups: [
                BundleGroup(ref: "g1", name: "A", parentRef: "g2"),
                BundleGroup(ref: "g2", name: "B", parentRef: "g1")
            ])
        }
        expectRefused(.cycle("g1")) { try Self.bundle(groups: [BundleGroup(ref: "g1", name: "A", parentRef: "g1")]) }
        expectRefused(.cycle("f2")) {
            try Self.bundle(folders: [
                BundleQueryFolder(ref: "f1", name: "Root"),
                BundleQueryFolder(ref: "f2", name: "A", parentRef: "f3"),
                BundleQueryFolder(ref: "f3", name: "B", parentRef: "f2")
            ])
        }
    }

    @Test("A group or folder chain deeper than the nesting limit is refused")
    func deepChainsAreRefused() throws {
        let limit = BundleViolation.maximumNestingDepth
        func folders(_ count: Int) -> [BundleQueryFolder] {
            (1...count).map { index in
                BundleQueryFolder(ref: BundleRef("f\(index)"), name: "F\(index)", parentRef: index == 1 ? nil : BundleRef("f\(index - 1)"))
            }
        }
        _ = try Self.bundle(folders: folders(limit))
        expectRefused(.tooDeep(BundleRef("f\(limit + 1)"))) { try Self.bundle(folders: folders(limit + 1)) }
        expectRefused(.tooDeep("g33")) {
            try Self.bundle(groups: (1...33).map { index in
                BundleGroup(ref: BundleRef("g\(index)"), name: "G\(index)", parentRef: index == 1 ? nil : BundleRef("g\(index - 1)"))
            })
        }
    }

    @Test("A query in a folder of another scope is not a structural error")
    func scopeMismatchIsAllowed() throws {
        let bundle = try Self.bundle(
            connections: [Self.connection("c1")],
            folders: [BundleQueryFolder(ref: "f1", name: "Scoped", connectionRef: "c1")],
            queries: [BundleSavedQuery(ref: "q1", name: "Global", sql: "SELECT 1", folderRef: "f1")]
        )

        #expect(bundle.folderChain(bundle.savedQueries.first?.folderRef).map(\.name) == ["Scoped"])
    }

    @Test("Chains run from the root, and an absent ref has none")
    func chainsRunFromTheRoot() throws {
        let bundle = try ConnectionBundleCodecTests.fullBundle()

        #expect(bundle.groupChain("g2").map(\.name) == ["Client A", "Production"])
        #expect(bundle.folderChain("f2").map(\.name) == ["Reports", "Daily"])
        #expect(bundle.groupChain(nil).isEmpty)
        #expect(bundle.groupChain("missing").isEmpty)
    }

    @Test("Lookups find connections and profiles by ref")
    func lookups() throws {
        let bundle = try ConnectionBundleCodecTests.fullBundle()

        #expect(bundle.connection("c2")?.settings.name == "Cache")
        #expect(bundle.connection("c9") == nil)
        #expect(bundle.credentialProfile("p1")?.name == "reader")
        #expect(bundle.credentialProfile(nil) == nil)
        #expect(bundle.savedQueryCount(for: "c1") == 1)
        #expect(bundle.savedQueryCount(for: "c2") == 0)
    }

    @Test("Dropping credentials keeps everything else")
    func withoutCredentialsKeepsTheRest() throws {
        let credentials = ExportableCredentials(
            password: "pw", sshPassword: nil, keyPassphrase: nil,
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
        )
        let bundle = try ConnectionBundle(
            appVersion: "1.0",
            connections: [Self.connection("c1")],
            credentials: ["c1": credentials]
        )

        let stripped = bundle.withoutCredentials()

        #expect(stripped.credentials.isEmpty)
        #expect(stripped.connections == bundle.connections)
        #expect(stripped.exportedAt == bundle.exportedAt)
    }

    @Test("Replacing settings changes only that connection")
    func replacingSettingsChangesOneConnection() throws {
        let bundle = try ConnectionBundleCodecTests.fullBundle()
        var renamed = try #require(bundle.connection("c1")?.settings)
        renamed.name = "Orders (Edited)"

        let updated = bundle.replacingSettings(renamed, of: "c1")

        #expect(updated.connection("c1")?.settings.name == "Orders (Edited)")
        #expect(updated.connection("c1")?.groupRef == "g2")
        #expect(updated.connection("c2") == bundle.connection("c2"))
        #expect(bundle.replacingSettings(renamed, of: "c9") == bundle)
    }

    private static let settings = ExportableConnection(
        name: "X", host: "h", port: 5_432, database: "d", username: "u", type: "PostgreSQL"
    )

    private static func connection(_ ref: BundleRef) -> BundleConnection {
        BundleConnection(ref: ref, settings: settings)
    }

    private static func profile(_ ref: BundleRef) -> BundleCredentialProfile {
        BundleCredentialProfile(ref: ref, name: "P", username: "u", passwordMode: .prompt)
    }

    private static func query(_ ref: BundleRef) -> BundleSavedQuery {
        BundleSavedQuery(ref: ref, name: "Q", sql: "SELECT 1")
    }

    private static func bundle(
        connections: [BundleConnection] = [],
        groups: [BundleGroup] = [],
        profiles: [BundleCredentialProfile] = [],
        folders: [BundleQueryFolder] = [],
        queries: [BundleSavedQuery] = []
    ) throws -> ConnectionBundle {
        try ConnectionBundle(
            appVersion: "1.0",
            connections: connections,
            groups: groups,
            credentialProfiles: profiles,
            queryFolders: folders,
            savedQueries: queries
        )
    }

    private func expectRefused(
        _ violation: BundleViolation,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> ConnectionBundle
    ) {
        #expect(throws: ConnectionBundleError.invalidBundle(violation.message), sourceLocation: sourceLocation) {
            _ = try build()
        }
    }
}
