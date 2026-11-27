import Foundation
import TableProConnectionLibrary
import TableProImport
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ConnectionProjectTransferTests {
    private let fixture: AppStateFixture
    private let store = MockSecureStore()
    private let appState: AppState

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, secureStore: store)
    }

    private func settings(_ name: String) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: "\(name.lowercased()).example.com",
            port: 5_432,
            database: "orders",
            username: "app",
            type: DatabaseType.postgresql.rawValue
        )
    }

    private func addProject(_ name: String) throws -> UUID {
        guard case .applied(let id) = appState.addProject(named: name) else {
            Issue.record("the project was not added")
            throw CancellationError()
        }
        return id
    }

    @discardableResult
    private func importing(_ bundle: ConnectionBundle) async throws -> ImportOutcome {
        let preview = try await IOSConnectionImportService.preview(
            of: ConnectionBundleCodec.decode(ConnectionBundleCodec.encode(bundle)),
            fileName: "Tests.tablepro",
            appState: appState
        )
        let plan = ImportPlanner.plan(
            preview,
            selection: .defaults(for: preview),
            targetProjectId: appState.activeProjectId
        )
        return await IOSConnectionImportService.apply(plan, appState: appState, secureStore: store)
    }

    @Test("An export from a project holds that project's connections, with the project on its groups and loose rows")
    func exportWritesWhatIsInScope() async throws {
        let projectId = try addProject("Acme")
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        #expect(appState.addGroup(group).isSaved)
        #expect(appState.addConnection(DatabaseConnection(name: "Grouped", type: .postgresql, groupId: group.id)))
        #expect(appState.addConnection(DatabaseConnection(name: "Loose", type: .postgresql, projectId: projectId)))
        #expect(appState.addConnection(DatabaseConnection(name: "Outside", type: .postgresql)))
        appState.setActiveProject(projectId)

        let data = try await IOSConnectionExportService.exportData(
            connections: appState.scopedConnections,
            appState: appState,
            includeCredentials: false,
            passphrase: nil
        )
        let bundle = try ConnectionBundleCodec.decode(data)

        #expect(Set(bundle.connections.map(\.settings.name)) == ["Grouped", "Loose"])
        #expect(bundle.projects.map(\.name) == ["Acme"])
        #expect(bundle.projects.first?.id == projectId)
        #expect(bundle.connections.map { bundle.project(of: $0)?.name } == ["Acme", "Acme"])
    }

    @Test("A file's project wins over the active one, and is created with the file's id when it is new")
    func importCreatesTheFilesProject() async throws {
        let active = try addProject("Internal")
        appState.setActiveProject(active)
        let fileProjectId = UUID()
        let spec = ConnectionBundleBuilder.ProjectSpec(id: fileProjectId, name: "Acme")
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(
            settings("Grouped"),
            ref: "c1",
            groupPath: [ConnectionBundleBuilder.GroupComponent(name: "Production")],
            project: spec
        )
        builder.addConnection(settings("Loose"), ref: "c2", project: spec)

        try await importing(try builder.build())

        #expect(appState.projects.first { $0.id == fileProjectId }?.name == "Acme")
        let grouped = try #require(appState.connections.first { $0.name == "Grouped" })
        let loose = try #require(appState.connections.first { $0.name == "Loose" })
        #expect(appState.group(for: grouped.groupId)?.projectId == fileProjectId)
        #expect(grouped.projectId == nil)
        #expect(loose.projectId == fileProjectId)
        #expect(appState.scopedConnections.isEmpty)
    }

    @Test("A file's project matches an existing one by name, and a second import adds no second project")
    func importMatchesByName() async throws {
        let existing = try addProject("Acme")
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings("Loose"), ref: "c1", project: .init(id: UUID(), name: " acme "))

        try await importing(try builder.build())

        #expect(appState.projects.map(\.id) == [existing])
        #expect(appState.connections.first?.projectId == existing)
    }

    @Test("A file that names no project lands in the active one, in its own top-level group of a name another project uses")
    func importLandsInTheActiveProject() async throws {
        let other = try addProject("Other")
        let active = try addProject("Acme")
        let othersGroup = ConnectionGroup(name: "Production", projectId: other)
        #expect(appState.addGroup(othersGroup).isSaved)
        appState.setActiveProject(active)
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(
            settings("Grouped"),
            ref: "c1",
            groupPath: [ConnectionBundleBuilder.GroupComponent(name: "Production")]
        )
        builder.addConnection(settings("Loose"), ref: "c2")

        try await importing(try builder.build())

        let grouped = try #require(appState.connections.first { $0.name == "Grouped" })
        let group = try #require(appState.group(for: grouped.groupId))
        #expect(group.id != othersGroup.id)
        #expect(group.projectId == active)
        #expect(appState.connections.first { $0.name == "Loose" }?.projectId == active)
        #expect(Set(appState.scopedConnections.map(\.name)) == ["Grouped", "Loose"])
    }

    @Test("A review opened in a project that is deleted before Import lands its connections in no project")
    func reviewFollowsTheActiveProject() async throws {
        let active = try addProject("Acme")
        appState.setActiveProject(active)
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings("Loose"), ref: "c1")
        let preview = try await IOSConnectionImportService.preview(
            of: ConnectionBundleCodec.decode(ConnectionBundleCodec.encode(try builder.build())),
            fileName: "Tests.tablepro",
            appState: appState
        )
        let review = MobileConnectionImportSheet.Review(preview: preview, selection: .defaults(for: preview))
        #expect(review.plan(targetProjectId: appState.activeProjectId).targetProjectId == active)

        appState.deleteProject(active)

        let plan = review.plan(targetProjectId: appState.activeProjectId)
        #expect(plan.targetProjectId == nil)
        _ = await IOSConnectionImportService.apply(plan, appState: appState, secureStore: store)
        #expect(appState.connections.first { $0.name == "Loose" }?.projectId == nil)
        #expect(appState.scopedConnections.map(\.name) == ["Loose"])
    }
}
