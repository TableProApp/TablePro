import Foundation
import Testing

@testable import TableProImport

@MainActor
private final class FakeLibraryStore: ImportLibraryStore {
    var failsToRead = false
    var refusesConnectionWrite = false
    var droppedConnectionIds: Set<UUID> = []
    var createdProfileRefs: Set<BundleRef>?
    var existingIds: Set<UUID> = []

    private(set) var receivedProfiles: [PlannedCredentialProfile] = []
    private(set) var receivedGroupPaths: [[PathComponent]] = []
    private(set) var receivedTags: [PlannedTag] = []
    private(set) var writtenConnections: [ResolvedConnection]?
    private(set) var credentialWrites: [(connectionId: UUID, password: String?)] = []

    private var nextId: UInt8 = 100

    func snapshot() async throws -> ImportLibrarySnapshot {
        if failsToRead { throw ImportStoreError.unreadable }
        return ImportLibrarySnapshot()
    }

    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] {
        if failsToRead { throw ImportStoreError.unreadable }
        receivedProfiles = profiles
        var created: [BundleRef: UUID] = [:]
        for profile in profiles where createdProfileRefs?.contains(profile.ref) ?? true {
            created[profile.ref] = makeId()
        }
        return created
    }

    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        receivedGroupPaths = paths
        return paths.map { _ in makeId() }
    }

    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID] {
        receivedTags = tags
        var ids: [String: UUID] = [:]
        for tag in tags {
            ids[tag.name.lowercased()] = makeId()
        }
        return ids
    }

    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite? {
        writtenConnections = connections
        guard !refusesConnectionWrite else { return nil }
        let persisted = connections.filter { !droppedConnectionIds.contains($0.planned.id) }
        return ConnectionImportWrite(
            added: persisted.filter { $0.planned.write == .add }.map(\.planned.id),
            replaced: persisted.filter { $0.planned.write == .replace }.map(\.planned.id)
        )
    }

    func existingConnectionIds() -> Set<UUID> {
        existingIds
    }

    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {
        credentialWrites.append((connectionId, credentials.password))
    }

    private func makeId() -> UUID {
        nextId += 1
        return ImportFixtures.uuid(nextId)
    }
}

private actor FakeSavedQueryStore: SavedQueryImportStore {
    private let fails: Bool
    private let alreadySaved: Int
    private let tooLarge: Int
    private(set) var received: [[PlannedQuery]] = []

    init(fails: Bool = false, alreadySaved: Int = 0, tooLarge: Int = 0) {
        self.fails = fails
        self.alreadySaved = alreadySaved
        self.tooLarge = tooLarge
    }

    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite? {
        received.append(queries)
        guard !fails else { return nil }
        let inserted = queries.dropLast(alreadySaved + tooLarge).map { _ in UUID() }
        return SavedQueryImportWrite(
            insertedIds: inserted,
            createdFolderIds: [],
            alreadySaved: alreadySaved,
            droppedKeywords: 0,
            tooLarge: tooLarge
        )
    }
}

@Suite("Import applier")
@MainActor
struct ImportApplierTests {
    private typealias Fixtures = ImportFixtures

    private func connection(
        _ ref: BundleRef,
        id: UUID,
        write: PlannedConnection.Write = .add,
        groupPath: [PathComponent] = [],
        tagNames: [String] = [],
        profile: BundleRef? = nil,
        password: String? = nil
    ) -> PlannedConnection {
        PlannedConnection(
            ref: ref,
            id: id,
            write: write,
            settings: Fixtures.settings(name: ref.rawValue),
            groupPath: groupPath,
            tagNames: tagNames,
            credentialProfileRef: profile,
            credentials: password.map { Fixtures.credentials(password: $0) }
        )
    }

    private func query(_ ref: BundleRef, connectionId: UUID?) -> PlannedQuery {
        PlannedQuery(ref: ref, name: ref.rawValue, sql: "select 1", keyword: nil, connectionId: connectionId, folderPath: [])
    }

    private func makePlan(
        connections: [PlannedConnection] = [],
        kept: [BundleRef: UUID] = [:],
        tags: [PlannedTag] = [],
        profiles: [PlannedCredentialProfile] = [],
        queries: [PlannedQuery] = []
    ) -> ImportPlan {
        ImportPlan(
            connections: connections,
            keptConnections: kept,
            tags: tags,
            credentialProfiles: profiles,
            queries: queries,
            queryStatuses: [:]
        )
    }

    @Test("Connections are written with resolved groups, tags and only the profiles this import created")
    func resolvesBeforeWriting() async throws {
        let library = FakeLibraryStore()
        library.createdProfileRefs = ["p1"]
        let teamA = [PathComponent(name: "Team A", scope: nil, color: nil)]
        let plan = makePlan(
            connections: [
                connection("c1", id: Fixtures.uuid(1), groupPath: teamA, tagNames: ["Prod", "prod"], profile: "p1"),
                connection("c2", id: Fixtures.uuid(2), groupPath: teamA, profile: "p2"),
                connection("c3", id: Fixtures.uuid(3))
            ],
            tags: [PlannedTag(name: "Prod", color: nil)],
            profiles: [
                PlannedCredentialProfile(ref: "p1", name: "new", username: "u", passwordMode: .prompt, secureFieldIds: []),
                PlannedCredentialProfile(ref: "p2", name: "existing", username: "u", passwordMode: .prompt, secureFieldIds: [])
            ]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: nil)

        #expect(outcome == ImportOutcome(connectionsAdded: 3))
        #expect(library.receivedGroupPaths == [teamA])
        let written = try #require(library.writtenConnections)
        #expect(written.map(\.groupId) == [Fixtures.uuid(102), Fixtures.uuid(102), nil])
        #expect(written.map(\.tagIds) == [[Fixtures.uuid(103)], [], []])
        #expect(written.map(\.credentialProfileId) == [Fixtures.uuid(101), nil, nil])
    }

    @Test("When no connection is saved, no credentials or queries are written")
    func nilConnectionWriteStops() async {
        let library = FakeLibraryStore()
        library.refusesConnectionWrite = true
        let queries = FakeSavedQueryStore()
        let plan = makePlan(
            connections: [connection("c1", id: Fixtures.uuid(1), password: "secret")],
            queries: [query("q1", connectionId: Fixtures.uuid(1)), query("q2", connectionId: nil)]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: queries)

        #expect(outcome == ImportOutcome(failure: .connectionsNotSaved))
        #expect(!outcome.importedAnything)
        #expect(library.credentialWrites.isEmpty)
        #expect(await queries.received.isEmpty)
    }

    @Test("Credentials and queries follow only the connections storage reports as saved")
    func onlyPersistedConnectionsGetCredentialsAndQueries() async {
        let library = FakeLibraryStore()
        library.droppedConnectionIds = [Fixtures.uuid(2)]
        let queries = FakeSavedQueryStore()
        let plan = makePlan(
            connections: [
                connection("c1", id: Fixtures.uuid(1), password: "one"),
                connection("c2", id: Fixtures.uuid(2), write: .replace, password: "two")
            ],
            queries: [query("q1", connectionId: Fixtures.uuid(1)), query("q2", connectionId: Fixtures.uuid(2))]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: queries)

        #expect(outcome == ImportOutcome(connectionsAdded: 1, savedQueriesAdded: 1, savedQueriesNotImported: 1))
        #expect(library.credentialWrites.map { $0.connectionId } == [Fixtures.uuid(1)])
        #expect(await queries.received.map { $0.map(\.ref) } == [["q1"]])
    }

    @Test("Credentials are written in plan order")
    func credentialsInPlanOrder() async {
        let library = FakeLibraryStore()
        let plan = makePlan(connections: [
            connection("c1", id: Fixtures.uuid(9), write: .replace, password: "first"),
            connection("c2", id: Fixtures.uuid(3), password: "second"),
            connection("c3", id: Fixtures.uuid(5)),
            connection("c4", id: Fixtures.uuid(1), write: .replace, password: "third")
        ])

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: nil)

        #expect(outcome == ImportOutcome(connectionsAdded: 2, connectionsReplaced: 2))
        #expect(library.credentialWrites.map { $0.password } == ["first", "second", "third"])
    }

    @Test("Queries of a Keep Existing connection that has since vanished are not imported")
    func vanishedKeepExistingTarget() async {
        let library = FakeLibraryStore()
        let present = UUID()
        let vanished = UUID()
        library.existingIds = [present]
        let queries = FakeSavedQueryStore()
        let plan = makePlan(
            kept: ["c1": present, "c2": vanished],
            queries: [query("q1", connectionId: present), query("q2", connectionId: vanished), query("q3", connectionId: nil)]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: queries)

        #expect(outcome == ImportOutcome(savedQueriesAdded: 2, savedQueriesNotImported: 1))
        #expect(library.writtenConnections == nil)
        #expect(await queries.received.map { $0.map(\.ref) } == [["q1", "q3"]])
    }

    @Test("Without a query store the connections still import")
    func noQueryStoreKeepsConnections() async {
        let library = FakeLibraryStore()
        let plan = makePlan(
            connections: [connection("c1", id: Fixtures.uuid(1))],
            queries: [query("q1", connectionId: Fixtures.uuid(1))]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: nil)

        #expect(outcome == ImportOutcome(connectionsAdded: 1, savedQueriesNotImported: 1))
    }

    @Test("A failed query write reports it and keeps the connections")
    func failedQueryWriteKeepsConnections() async {
        let library = FakeLibraryStore()
        let plan = makePlan(
            connections: [connection("c1", id: Fixtures.uuid(1))],
            queries: [query("q1", connectionId: Fixtures.uuid(1))]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: FakeSavedQueryStore(fails: true))

        #expect(outcome == ImportOutcome(connectionsAdded: 1, failure: .savedQueriesNotSaved))
        #expect(outcome.importedAnything)
    }

    @Test("Queries storage found already saved or too large count as not imported")
    func storageSkipsCount() async {
        let library = FakeLibraryStore()
        let plan = makePlan(queries: [
            query("q1", connectionId: nil), query("q2", connectionId: nil), query("q3", connectionId: nil)
        ])

        let outcome = await ImportApplier.apply(
            plan,
            library: library,
            savedQueries: FakeSavedQueryStore(alreadySaved: 1, tooLarge: 1)
        )

        #expect(outcome == ImportOutcome(savedQueriesAdded: 1, savedQueriesNotImported: 2))
    }

    @Test("An unreadable library stops before anything is written")
    func unreadableLibraryStops() async {
        let library = FakeLibraryStore()
        library.failsToRead = true
        let plan = makePlan(
            connections: [connection("c1", id: Fixtures.uuid(1), profile: "p1", password: "secret")],
            profiles: [PlannedCredentialProfile(ref: "p1", name: "n", username: "u", passwordMode: .prompt, secureFieldIds: [])]
        )

        let outcome = await ImportApplier.apply(plan, library: library, savedQueries: nil)

        #expect(outcome == ImportOutcome(failure: .libraryUnreadable))
        #expect(library.writtenConnections == nil)
        #expect(library.credentialWrites.isEmpty)
    }
}
