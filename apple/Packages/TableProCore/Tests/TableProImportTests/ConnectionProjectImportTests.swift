import Foundation
import TableProConnectionLibrary
import Testing

@testable import TableProImport

private struct ExistingProject: LibraryProjectRepresentable {
    var id: UUID
    var name: String
    var sortOrder = 0
}

struct ConnectionBundleProjectTests {
    private typealias Fixtures = ImportFixtures

    private static let acmeId = Fixtures.uuid(200)

    // Whole seconds, which is what the file keeps of the export time.
    private static func makeBundle(
        connections: [BundleConnection],
        groups: [BundleGroup] = [],
        projects: [BundleProject] = []
    ) throws -> ConnectionBundle {
        try ConnectionBundle(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "Tests",
            connections: connections,
            groups: groups,
            projects: projects
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func projectBundle() throws -> ConnectionBundle {
        try Self.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Orders"), groupRef: "g1"),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Cache"), projectRef: "j1")
            ],
            groups: [BundleGroup(ref: "g1", name: "Production", projectRef: "j1")],
            projects: [BundleProject(ref: "j1", id: Self.acmeId, name: "Acme", color: "Blue", iconName: "shippingbox")]
        )
    }

    @Test("Projects and their refs survive a format 2 round trip")
    func roundTrip() throws {
        let bundle = try projectBundle()

        let data = try ConnectionBundleCodec.encode(bundle)
        let object = try jsonObject(data)
        let decoded = try ConnectionBundleCodec.decode(data)

        #expect(object["formatVersion"] as? Int == 2)
        #expect((object["projects"] as? [[String: Any]])?.first?["name"] as? String == "Acme")
        #expect(decoded == bundle)
        #expect(decoded.project(of: decoded.connections[0])?.id == Self.acmeId)
        #expect(decoded.project(of: decoded.connections[1])?.id == Self.acmeId)
    }

    @Test("A flat bundle that names a project is not written in format 1")
    func projectKeepsFormatTwo() throws {
        let loose = try Self.makeBundle(
            connections: [BundleConnection(ref: "0", settings: Fixtures.settings(), projectRef: "j1")],
            projects: [BundleProject(ref: "j1", name: "Acme")]
        )
        let grouped = try Self.makeBundle(
            connections: [BundleConnection(ref: "0", settings: Fixtures.settings(), groupRef: "g1")],
            groups: [BundleGroup(ref: "g1", name: "Production", projectRef: "j1")],
            projects: [BundleProject(ref: "j1", name: "Acme")]
        )
        let unused = try Self.makeBundle(
            connections: [BundleConnection(ref: "0", settings: Fixtures.settings())],
            projects: [BundleProject(ref: "j1", name: "Acme")]
        )
        let plain = try Self.makeBundle(connections: [BundleConnection(ref: "0", settings: Fixtures.settings())])

        for bundle in [loose, grouped, unused] {
            let data = try ConnectionBundleCodec.encode(bundle)
            #expect(try jsonObject(data)["formatVersion"] as? Int == 2)
            #expect(try ConnectionBundleCodec.decode(data) == bundle)
        }
        #expect(try jsonObject(ConnectionBundleCodec.encode(plain))["formatVersion"] as? Int == 1)
    }

    @Test("A format 2 file written before projects decodes with none")
    func fileWithoutProjectsDecodes() throws {
        let json = """
        {"formatVersion":2,"exportedAt":"2026-01-01T00:00:00Z","appVersion":"0.80.0",
         "connections":[{"ref":"c1","name":"Orders","host":"db","port":5432,"database":"orders",
                         "username":"app","type":"PostgreSQL","groupRef":"g1"}],
         "groups":[{"ref":"g1","name":"Production"}]}
        """

        let bundle = try ConnectionBundleCodec.decode(Data(json.utf8))

        #expect(bundle.projects.isEmpty)
        #expect(bundle.connections.first?.projectRef == nil)
        #expect(bundle.groups.first?.projectRef == nil)
        #expect(bundle.project(of: bundle.connections[0]) == nil)
    }

    @Test("A project ref that is not in the file is refused, and so is a repeated one")
    func brokenProjectRefs() {
        #expect(throws: ConnectionBundleError.self) {
            try Self.makeBundle(
                connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(), projectRef: "j9")]
            )
        }
        #expect(throws: ConnectionBundleError.self) {
            try Self.makeBundle(
                connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
                groups: [BundleGroup(ref: "g1", name: "Production", projectRef: "j9")]
            )
        }
        #expect(throws: ConnectionBundleError.self) {
            try Self.makeBundle(
                connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
                projects: [BundleProject(ref: "j1", name: "Acme"), BundleProject(ref: "j1", name: "Globex")]
            )
        }
    }

    @Test("A grouped connection follows its top-level group, whatever it stores itself")
    func groupedConnectionFollowsRoot() throws {
        let bundle = try Self.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(), groupRef: "g2", projectRef: "j2")
            ],
            groups: [
                BundleGroup(ref: "g1", name: "Production", projectRef: "j1"),
                BundleGroup(ref: "g2", name: "EU", parentRef: "g1", projectRef: "j2")
            ],
            projects: [BundleProject(ref: "j1", name: "Acme"), BundleProject(ref: "j2", name: "Globex")]
        )

        #expect(bundle.project(of: bundle.connections[0])?.name == "Acme")
    }

    @Test("The builder keeps one top-level group per project and name")
    func builderScopesRootGroups() throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        let acme = ConnectionBundleBuilder.ProjectSpec(id: Self.acmeId, name: "Acme", color: "Blue")
        let globex = ConnectionBundleBuilder.ProjectSpec(name: "Globex")
        builder.addConnection(Fixtures.settings(name: "a"), ref: "c1", groupPath: [.init(name: "Production")], project: acme)
        builder.addConnection(Fixtures.settings(name: "b"), ref: "c2", groupPath: [.init(name: "production")], project: acme)
        builder.addConnection(Fixtures.settings(name: "c"), ref: "c3", groupPath: [.init(name: "Production")], project: globex)
        builder.addConnection(Fixtures.settings(name: "d"), ref: "c4", groupPath: [.init(name: "Production")])
        builder.addConnection(Fixtures.settings(name: "e"), ref: "c5", project: .init(name: " globex "))

        let bundle = try builder.build()

        #expect(bundle.projects.map(\.name) == ["Acme", "Globex"])
        #expect(bundle.projects.first?.id == Self.acmeId)
        #expect(bundle.groups.map(\.projectRef) == ["j1", "j2", nil])
        #expect(bundle.connections.map(\.groupRef) == ["g1", "g1", "g2", "g3", nil])
        #expect(bundle.connections.map(\.projectRef) == [nil, nil, nil, nil, "j2"])
    }

    @Test("Export writes each connection's project, taken from its top-level group when it has one")
    func assemblerCarriesProjects() throws {
        let rootId = UUID()
        let childId = UUID()
        let input = BundleExportInput(
            connections: [
                .init(id: UUID(), settings: Fixtures.settings(name: "a"), groupId: childId, projectId: UUID()),
                .init(id: UUID(), settings: Fixtures.settings(name: "b"), projectId: Self.acmeId),
                .init(id: UUID(), settings: Fixtures.settings(name: "c"), projectId: UUID()),
                .init(id: UUID(), settings: Fixtures.settings(name: "d"))
            ],
            groups: [
                .init(id: rootId, name: "Production", projectId: Self.acmeId),
                .init(id: childId, name: "EU", parentId: rootId)
            ],
            projects: [.init(id: Self.acmeId, name: "Acme", color: "Blue"), .init(id: UUID(), name: "Unused")]
        )

        let bundle = try BundleExportAssembler.assemble(input, options: .connectionsOnly, appVersion: "Tests")

        #expect(bundle.projects == [BundleProject(ref: "j1", id: Self.acmeId, name: "Acme", color: "Blue")])
        #expect(bundle.groups.map(\.projectRef) == ["j1", nil])
        #expect(bundle.connections.map(\.projectRef) == [nil, "j1", nil, nil])
        #expect(bundle.connections.map { bundle.project(of: $0)?.name } == ["Acme", "Acme", nil, nil])
    }
}

struct ImportProjectResolverTests {
    private typealias Fixtures = ImportFixtures

    private func planned(_ ref: BundleRef, id: UUID? = nil, name: String) -> PlannedProject {
        PlannedProject(ref: ref, id: id, name: name, color: "Blue", iconName: nil)
    }

    @Test("A project is matched by id first, then by name across case and Unicode form")
    func matchesByIdThenName() {
        let byId = ExistingProject(id: Fixtures.uuid(1), name: "Renamed", sortOrder: 0)
        let byName = ExistingProject(id: Fixtures.uuid(2), name: "Caf\u{00E9}", sortOrder: 1)

        let resolved = ImportProjectResolver.resolve(
            [
                planned("j1", id: Fixtures.uuid(1), name: "Acme"),
                planned("j2", id: Fixtures.uuid(9), name: " CAFE\u{0301} "),
                planned("j3", name: "renamed")
            ],
            existing: [byId, byName]
        )

        #expect(resolved.created.isEmpty)
        #expect(resolved.ids == ["j1": byId.id, "j2": byName.id, "j3": byId.id])
    }

    @Test("A missing project is created once, after the existing ones, with the file's id")
    func createsMissing() {
        var ids = SequentialIds()
        let existing = ExistingProject(id: Fixtures.uuid(50), name: "Globex", sortOrder: 4)

        let resolved = ImportProjectResolver.resolve(
            [
                planned("j1", id: Fixtures.uuid(60), name: "Acme"),
                planned("j2", name: "acme"),
                planned("j3", name: "Initech"),
                planned("j4", name: "  ")
            ],
            existing: [existing]
        ) { ids.next() }

        #expect(resolved.created.map(\.name) == ["Acme", "Initech"])
        #expect(resolved.created.map(\.id) == [Fixtures.uuid(60), Fixtures.uuid(1)])
        #expect(resolved.created.map(\.sortOrder) == [5, 6])
        #expect(resolved.created.first?.color == "Blue")
        #expect(resolved.ids == ["j1": Fixtures.uuid(60), "j2": Fixtures.uuid(60), "j3": Fixtures.uuid(1)])
    }

    @Test("A file's id that is taken here is not reused")
    func takenIdIsReplaced() {
        var ids = SequentialIds()

        let resolved = ImportProjectResolver.resolve(
            [planned("j1", id: Fixtures.uuid(60), name: "Acme")],
            existing: [ExistingProject](),
            takenIds: [Fixtures.uuid(60)]
        ) { ids.next() }

        #expect(resolved.created.map(\.id) == [Fixtures.uuid(1)])
    }

    @Test("Of two existing projects with one name the first in the list order is used")
    func duplicateNamesPickTheFirst() {
        let later = ExistingProject(id: Fixtures.uuid(1), name: "Acme", sortOrder: 3)
        let earlier = ExistingProject(id: Fixtures.uuid(2), name: "acme", sortOrder: 1)

        let resolved = ImportProjectResolver.resolve([planned("j1", name: "ACME")], existing: [later, earlier])

        #expect(resolved.ids == ["j1": earlier.id])
    }
}

struct ImportPlannerProjectTests {
    private typealias Fixtures = ImportFixtures

    @Test("The plan names each connection's project and lists only the projects it uses")
    func planCarriesProjects() throws {
        let target = Fixtures.uuid(77)
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Orders"), groupRef: "g1"),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Cache", host: "cache"), projectRef: "j2"),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "Local", host: "localhost"))
            ],
            groups: [BundleGroup(ref: "g1", name: "Production", projectRef: "j1")],
            projects: [
                BundleProject(ref: "j1", id: Fixtures.uuid(90), name: " Acme "),
                BundleProject(ref: "j2", name: "Globex"),
                BundleProject(ref: "j3", name: "Unused")
            ]
        )
        let preview = Fixtures.makePreview(bundle)
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(false, connection: "c2", in: preview)

        let plan = ImportPlanner.plan(preview, selection: selection, targetProjectId: target)

        #expect(plan.targetProjectId == target)
        #expect(plan.connections.map(\.projectRef) == ["j1", nil])
        #expect(plan.projects == [PlannedProject(ref: "j1", id: Fixtures.uuid(90), name: "Acme", color: nil, iconName: nil)])
    }
}

@MainActor
private final class ProjectLibraryStore: ImportLibraryStore {
    var resolvedProjects: [BundleRef: UUID] = [:]
    private(set) var receivedProjects: [PlannedProject] = []
    private(set) var receivedGroupPaths: [[PathComponent]] = []
    private(set) var writtenConnections: [ResolvedConnection] = []

    func snapshot() async throws -> ImportLibrarySnapshot { ImportLibrarySnapshot() }
    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] { [:] }
    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID] { [:] }
    func existingConnectionIds() -> Set<UUID> { [] }
    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {}

    func ensureProjects(_ projects: [PlannedProject]) throws -> [BundleRef: UUID] {
        receivedProjects = projects
        return resolvedProjects
    }

    var savedProjects: [UUID: UUID?] = [:]

    func projectIds(ofSavedConnections ids: Set<UUID>) -> [UUID: UUID?] {
        savedProjects.filter { ids.contains($0.key) }
    }

    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        receivedGroupPaths = paths
        return paths.indices.map { ImportFixtures.uuid(UInt8(150 + $0)) }
    }

    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite? {
        writtenConnections = connections
        return ConnectionImportWrite(added: connections.map(\.planned.id), replaced: [])
    }
}

@MainActor
private final class ProjectlessLibraryStore: ImportLibraryStore {
    private(set) var writtenConnections: [ResolvedConnection] = []

    func snapshot() async throws -> ImportLibrarySnapshot { ImportLibrarySnapshot() }
    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] { [:] }
    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] { paths.map { _ in nil } }
    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID] { [:] }
    func existingConnectionIds() -> Set<UUID> { [] }
    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {}

    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite? {
        writtenConnections = connections
        return ConnectionImportWrite(added: connections.map(\.planned.id), replaced: [])
    }
}

@MainActor
struct ImportApplierProjectTests {
    private typealias Fixtures = ImportFixtures

    private let acme = ImportFixtures.uuid(201)
    private let active = ImportFixtures.uuid(202)

    private func connection(
        _ ref: BundleRef,
        id: UInt8,
        group: String? = nil,
        project: BundleRef? = nil,
        write: PlannedConnection.Write = .add
    ) -> PlannedConnection {
        PlannedConnection(
            ref: ref,
            id: Fixtures.uuid(id),
            write: write,
            settings: Fixtures.settings(name: ref.rawValue),
            groupPath: group.map { [PathComponent(name: $0, scope: nil, color: nil), PathComponent(name: "EU", scope: nil, color: nil)] } ?? [],
            tagNames: [],
            credentialProfileRef: nil,
            credentials: nil,
            projectRef: project
        )
    }

    private func plan(_ connections: [PlannedConnection], target: UUID?) -> ImportPlan {
        ImportPlan(
            connections: connections,
            keptConnections: [:],
            tags: [],
            credentialProfiles: [],
            queries: [],
            queryStatuses: [:],
            projects: [PlannedProject(ref: "j1", id: nil, name: "Acme", color: nil, iconName: nil)],
            targetProjectId: target
        )
    }

    @Test("The file's project wins over the caller's, and a connection it names none for takes the caller's")
    func fileProjectWins() async {
        let library = ProjectLibraryStore()
        library.resolvedProjects = ["j1": acme]

        _ = await ImportApplier.apply(
            plan([connection("c1", id: 1, project: "j1"), connection("c2", id: 2)], target: active),
            library: library,
            savedQueries: nil
        )

        #expect(library.receivedProjects.map(\.name) == ["Acme"])
        #expect(library.writtenConnections.map(\.projectId) == [acme, active])
    }

    @Test("A top-level group is matched and made in the connection's project, and its connections store none")
    func groupsAreScopedToTheProject() async {
        let library = ProjectLibraryStore()
        library.resolvedProjects = ["j1": acme]

        _ = await ImportApplier.apply(
            plan(
                [
                    connection("c1", id: 1, group: "Production", project: "j1"),
                    connection("c2", id: 2, group: "Production"),
                    connection("c3", id: 3, group: "Production", project: "j1")
                ],
                target: active
            ),
            library: library,
            savedQueries: nil
        )

        #expect(library.receivedGroupPaths.map { $0.map(\.scope) } == [[acme, nil], [active, nil]])
        #expect(library.writtenConnections.map(\.groupId) == [Fixtures.uuid(150), Fixtures.uuid(151), Fixtures.uuid(150)])
        #expect(library.writtenConnections.map(\.projectId) == [nil, nil, nil])
    }

    @Test("A replaced connection stays in its project, with its groups, unless the file names another")
    func replacedConnectionKeepsItsProject() async {
        let globex = Fixtures.uuid(203)
        let library = ProjectLibraryStore()
        library.resolvedProjects = ["j1": acme]
        library.savedProjects = [
            Fixtures.uuid(1): globex,
            Fixtures.uuid(2): globex,
            Fixtures.uuid(3): nil,
            Fixtures.uuid(4): globex,
            Fixtures.uuid(5): globex
        ]

        _ = await ImportApplier.apply(
            plan(
                [
                    connection("c1", id: 1, write: .replace),
                    connection("c2", id: 2, group: "Production", write: .replace),
                    connection("c3", id: 3, group: "Production", write: .replace),
                    connection("c4", id: 4, project: "j1", write: .replace),
                    connection("c5", id: 5, group: "Production"),
                    connection("c6", id: 6, write: .replace)
                ],
                target: active
            ),
            library: library,
            savedQueries: nil
        )

        #expect(library.receivedGroupPaths.map { $0.map(\.scope) } == [[globex, nil], [nil, nil], [active, nil]])
        #expect(library.writtenConnections.map(\.projectId) == [globex, nil, nil, acme, nil, active])
        #expect(library.writtenConnections.map(\.groupId) == [
            nil, Fixtures.uuid(150), Fixtures.uuid(151), nil, Fixtures.uuid(152), nil
        ])
    }

    @Test("With no target and no project in the file nothing is scoped")
    func noProjectAnywhere() async {
        let library = ProjectLibraryStore()

        _ = await ImportApplier.apply(
            plan([connection("c1", id: 1, group: "Production"), connection("c2", id: 2)], target: nil),
            library: library,
            savedQueries: nil
        )

        #expect(library.receivedGroupPaths.map { $0.map(\.scope) } == [[nil, nil]])
        #expect(library.writtenConnections.map(\.projectId) == [nil, nil])
    }

    @Test("A store that keeps no projects puts every connection in the caller's project")
    func storeWithoutProjects() async {
        let library = ProjectlessLibraryStore()

        _ = await ImportApplier.apply(
            plan([connection("c1", id: 1, project: "j1"), connection("c2", id: 2)], target: active),
            library: library,
            savedQueries: nil
        )

        #expect(library.writtenConnections.map(\.projectId) == [active, active])
    }
}
