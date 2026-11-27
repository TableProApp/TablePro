import Combine
import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct ConnectionProjectSharingTests {
    private func settings(_ name: String, host: String) -> ExportableConnection {
        ExportableConnection(name: name, host: host, port: 5_432, database: "", username: "", type: "PostgreSQL")
    }

    private func connection(_ name: String, in library: ImportLibraryFixture) throws -> DatabaseConnection {
        try #require(library.connections.loadConnections().first { $0.name == name })
    }

    @Test("An export names the project of each connection, through its top-level group for a grouped one")
    func exportCarriesProjects() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let acme = try library.projects.createProject(name: "Acme", color: .blue, iconName: "briefcase")
        try library.projects.createProject(name: "Unused")
        let production = ConnectionGroup(name: "Production", projectId: acme.id)
        try library.groups.addGroup(production)
        let grouped = DatabaseConnection(name: "Orders", host: "orders.example.com", type: .postgresql, groupId: production.id)
        let loose = DatabaseConnection(name: "Billing", host: "billing.example.com", type: .postgresql, projectId: acme.id)
        let unfiled = DatabaseConnection(name: "Scratch", host: "scratch.example.com", type: .postgresql)

        let bundle = try library.exporter.connectionsOnlyBundle(for: [grouped, loose, unfiled])

        #expect(bundle.projects.map(\.name) == ["Acme"])
        #expect(bundle.projects.first?.id == acme.id)
        #expect(bundle.connection("c1").flatMap { bundle.project(of: $0) }?.id == acme.id)
        #expect(bundle.connection("c2").flatMap { bundle.project(of: $0) }?.id == acme.id)
        #expect(bundle.connection("c3").flatMap { bundle.project(of: $0) } == nil)
    }

    @Test("A library with no projects exports a file with no project in it")
    func exportWithoutProjects() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }

        let bundle = try library.exporter.connectionsOnlyBundle(
            for: [DatabaseConnection(name: "Scratch", host: "scratch.example.com", type: .postgresql)]
        )

        #expect(bundle.projects.isEmpty)
        #expect(bundle.connection("c1")?.projectRef == nil)
    }

    @Test("An import makes the file's project and files its connections and top-level groups in it")
    func importCreatesTheProject() async throws {
        let source = try ImportLibraryFixture()
        defer { source.cleanUp() }
        let acme = try source.projects.createProject(name: "Acme", color: .blue)
        let production = ConnectionGroup(name: "Production", projectId: acme.id)
        try source.groups.addGroup(production)
        let bundle = try source.exporter.connectionsOnlyBundle(for: [
            DatabaseConnection(name: "Orders", host: "orders.example.com", type: .postgresql, groupId: production.id),
            DatabaseConnection(name: "Billing", host: "billing.example.com", type: .postgresql, projectId: acme.id),
        ])

        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let outcome = try await library.importDefaults(of: bundle)

        #expect(outcome.connectionsAdded == 2)
        let project = try #require(library.projects.loadProjects().first)
        #expect(project.id == acme.id)
        #expect(project.name == "Acme")
        #expect(project.color == .blue)
        let group = try #require(library.groups.loadGroups().first)
        #expect(group.projectId == acme.id)
        let orders = try connection("Orders", in: library)
        let billing = try connection("Billing", in: library)
        #expect(orders.groupId == group.id)
        #expect(orders.projectId == nil)
        #expect(billing.projectId == acme.id)
    }

    @Test("The file's project wins over the active one, matched by name, and a connection in none takes the active one")
    func fileProjectWinsOverTheTarget() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let acme = try library.projects.createProject(name: "Acme")
        let active = try library.projects.createProject(name: "Active")
        let existing = ConnectionGroup(name: "Production", projectId: active.id)
        try library.groups.addGroup(existing)
        let bundle = try ConnectionBundle(
            appVersion: "Tests",
            connections: [
                BundleConnection(ref: "c1", settings: settings("Orders", host: "orders.example.com"), projectRef: "p1"),
                BundleConnection(ref: "c2", settings: settings("Billing", host: "billing.example.com")),
                BundleConnection(ref: "c3", settings: settings("Ledger", host: "ledger.example.com"), groupRef: "g1"),
            ],
            groups: [BundleGroup(ref: "g1", name: "Production", projectRef: "p1")],
            projects: [BundleProject(ref: "p1", name: "acme")]
        )

        let outcome = try await library.importDefaults(of: bundle, targetProjectId: active.id)

        #expect(outcome.connectionsAdded == 3)
        #expect(library.projects.loadProjects().map(\.id) == [acme.id, active.id])
        #expect(try connection("Orders", in: library).projectId == acme.id)
        #expect(try connection("Billing", in: library).projectId == active.id)
        let ledger = try connection("Ledger", in: library)
        let ledgerGroup = try #require(ledger.groupId.flatMap { library.groups.group(for: $0) })
        #expect(ledgerGroup.id != existing.id)
        #expect(ledgerGroup.projectId == acme.id)
        #expect(ledger.projectId == nil)
    }

    @Test("With no active project and no project in the file, an import lands in no project")
    func importWithoutProjects() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let bundle = try ConnectionBundle(
            appVersion: "Tests",
            connections: [BundleConnection(ref: "c1", settings: settings("Orders", host: "orders.example.com"))]
        )

        let outcome = try await library.importDefaults(of: bundle)

        #expect(outcome.connectionsAdded == 1)
        #expect(library.projects.loadProjects().isEmpty)
        #expect(try connection("Orders", in: library).projectId == nil)
    }

    @Test("A connection an import replaces stays in its own project, grouped or not, whatever project is active")
    func replacedConnectionKeepsItsProject() async throws {
        let ordersId = UUID()
        let billingId = UUID()
        // The file names no project, so only the saved connection's own can keep it out of the active one.
        let source = try ImportLibraryFixture()
        defer { source.cleanUp() }
        let sourceGroup = ConnectionGroup(name: "Production")
        try source.groups.addGroup(sourceGroup)
        let bundle = try source.exporter.connectionsOnlyBundle(for: [
            DatabaseConnection(id: ordersId, name: "Orders", host: "orders.example.com", type: .postgresql, groupId: sourceGroup.id),
            DatabaseConnection(id: billingId, name: "Billing", host: "billing.example.com", type: .postgresql),
        ])
        #expect(bundle.projects.isEmpty)

        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let active = try library.projects.createProject(name: "Active")
        let other = try library.projects.createProject(name: "Other")
        let production = ConnectionGroup(name: "Production", projectId: other.id)
        try library.groups.addGroup(production)
        library.connections.addConnection(DatabaseConnection(
            id: ordersId, name: "Orders", host: "orders.example.com", type: .postgresql, groupId: production.id
        ))
        library.connections.addConnection(DatabaseConnection(
            id: billingId, name: "Billing", host: "billing.example.com", type: .postgresql, projectId: other.id
        ))

        let outcome = try await library.importDefaults(
            of: bundle, targetProjectId: active.id, choosing: { selection, preview in
                for row in preview.connections {
                    selection.setSelected(true, connection: row.ref, in: preview)
                    let replace = row.resolutions.first { resolution in
                        if case .replace = resolution { return true }
                        return false
                    }
                    if let replace {
                        selection.resolve(row.ref, as: replace, in: preview)
                    }
                }
            }
        )

        #expect(outcome.connectionsReplaced == 2)
        #expect(library.groups.loadGroups().map(\.id) == [production.id])
        let orders = try connection("Orders", in: library)
        let billing = try connection("Billing", in: library)
        #expect(orders.groupId == production.id)
        #expect(orders.projectId == nil)
        #expect(library.groups.group(for: production.id)?.projectId == other.id)
        #expect(billing.projectId == other.id)
    }

    @Test("An import review open while the active project changes plans for the project in force")
    func reviewFollowsTheScopeSignal() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let active = try library.projects.createProject(name: "Active")
        let bundle = try ConnectionBundle(
            appVersion: "Tests",
            connections: [BundleConnection(ref: "c1", settings: settings("Orders", host: "orders.example.com"))]
        )
        let preview = ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Shared.tablepro")),
            library: try await library.store.snapshot(),
            environment: ImportLibraryFixture.environment()
        )
        let target = TargetProject(active.id)
        let scopeChanged = PassthroughSubject<Void, Never>()
        let review = ImportReview(
            preview: preview,
            library: library.store,
            savedQueries: library.favorites,
            targetProjectId: { target.id },
            scopeChanged: scopeChanged.eraseToAnyPublisher()
        )
        #expect(review.plan.targetProjectId == active.id)

        // The active project was deleted under the open sheet.
        target.id = nil
        scopeChanged.send()

        #expect(review.plan.targetProjectId == nil)
    }
}

@MainActor
private final class TargetProject {
    var id: UUID?

    init(_ id: UUID?) {
        self.id = id
    }
}
