import Foundation
import Testing

@testable import TableProImport

@Suite("Import planner: connections")
struct ImportPlannerConnectionTests {
    private typealias Fixtures = ImportFixtures

    private func plan(_ preview: ImportPreview, _ configure: (inout ImportSelection) -> Void = { _ in }) -> ImportPlan {
        var selection = ImportSelection.defaults(for: preview)
        configure(&selection)
        var ids = SequentialIds()
        return ImportPlanner.plan(preview, selection: selection, ids: &ids)
    }

    @Test("As Copy adds a renamed duplicate with a new id and keeps its settings")
    func asCopyImportsARenamedDuplicate() throws {
        var imported = Fixtures.settings(name: "Imported")
        imported.connectTimeoutSeconds = 600
        imported.queryTimeoutSeconds = 45
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), name: "Existing")])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: imported)]),
            library: library
        )

        let result = plan(preview) { $0.setSelected(true, connection: "c1", in: preview) }

        let planned = try #require(result.connections.first)
        #expect(planned.id == Fixtures.uuid(1))
        #expect(planned.write == .add)
        #expect(planned.settings.name == "Imported (Imported)")
        #expect(planned.settings.connectTimeoutSeconds == 600)
        #expect(planned.settings.queryTimeoutSeconds == 45)
    }

    @Test("As Copy resolves name collisions with a numeric suffix")
    func asCopyResolvesNameCollisions() throws {
        let library = ImportLibrarySnapshot(connections: [
            Fixtures.existing(Fixtures.settings(), name: "Imported"),
            Fixtures.existing(Fixtures.settings(host: "a"), name: "imported (imported)"),
            Fixtures.existing(Fixtures.settings(host: "b"), name: "Imported (Imported 2)")
        ])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Imported"))]),
            library: library
        )

        let result = plan(preview) { $0.setSelected(true, connection: "c1", in: preview) }

        #expect(result.connections.first?.settings.name == "Imported (Imported 3)")
    }

    @Test("Names planned earlier in the same import count as taken")
    func plannedNamesAreTaken() throws {
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), name: "Orders")])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Orders")),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Orders"))
            ]),
            library: library
        )

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c1", in: preview)
            selection.setSelected(true, connection: "c2", in: preview)
        }

        #expect(result.connections.map(\.settings.name) == ["Orders (Imported)", "Orders (Imported 2)"])
    }

    @Test("Add keeps the file name, Replace reuses the existing id, Keep Existing writes nothing")
    func resolutionsDecideIdsAndWrites() throws {
        let replacedId = UUID()
        let keptId = UUID()
        var replacing = Fixtures.settings(name: "Replacement", host: "replace.example.com")
        replacing.connectTimeoutSeconds = 12
        replacing.queryTimeoutSeconds = 0
        let library = ImportLibrarySnapshot(connections: [
            Fixtures.existing(Fixtures.settings(host: "replace.example.com"), id: replacedId, name: "Old"),
            Fixtures.existing(Fixtures.settings(host: "kept.example.com"), id: keptId, name: "Kept")
        ])
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Fresh")),
                BundleConnection(ref: "c2", settings: replacing),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "Kept", host: "kept.example.com"))
            ],
            savedQueries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c3")]
        )
        let preview = Fixtures.makePreview(bundle, library: library)

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c2", in: preview)
            selection.resolve("c2", as: .replace(replacedId), in: preview)
            selection.setSelected(true, connection: "c3", in: preview)
        }

        #expect(result.connections.map(\.ref) == ["c1", "c2"])
        #expect(result.connections[0].id == Fixtures.uuid(1))
        #expect(result.connections[0].write == .add)
        #expect(result.connections[0].settings.name == "Fresh")
        #expect(result.connections[1].id == replacedId)
        #expect(result.connections[1].write == .replace)
        #expect(result.connections[1].settings.name == "Replacement")
        #expect(result.connections[1].settings.connectTimeoutSeconds == 12)
        #expect(result.connections[1].settings.queryTimeoutSeconds == 0)
        #expect(result.keptConnections == ["c3": keptId])
    }

    @Test("Only rows that write configuration bring their groups, tags and credential profiles")
    func onlyWrittenRowsContribute() throws {
        let keptId = UUID()
        let library = ImportLibrarySnapshot(connections: [
            Fixtures.existing(Fixtures.settings(host: "kept.example.com"), id: keptId)
        ])
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "One"), groupRef: "g1", tagNames: ["prod"], credentialProfileRef: "p1"),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Two", host: "two"), groupRef: "g2", tagNames: ["staging"], credentialProfileRef: "p2"),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "Kept", host: "kept.example.com"), groupRef: "g3", tagNames: ["kept"], credentialProfileRef: "p3")
            ],
            groups: [
                BundleGroup(ref: "g1", name: "Team A", color: "Blue"),
                BundleGroup(ref: "g2", name: "Team B"),
                BundleGroup(ref: "g3", name: "Team C")
            ],
            tags: [BundleTag(name: "prod", color: "Red"), BundleTag(name: "staging"), BundleTag(name: "kept")],
            credentialProfiles: [
                BundleCredentialProfile(ref: "p1", name: "reader", username: "ro", passwordMode: .stored),
                BundleCredentialProfile(ref: "p2", name: "writer", username: "rw", passwordMode: .prompt),
                BundleCredentialProfile(ref: "p3", name: "admin", username: "root", passwordMode: .prompt)
            ],
            savedQueries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c3")]
        )
        let preview = Fixtures.makePreview(bundle, library: library)

        let result = plan(preview) { selection in
            selection.setSelected(false, connection: "c2", in: preview)
            selection.setSelected(true, connection: "c3", in: preview)
        }

        #expect(result.connections.map(\.ref) == ["c1"])
        #expect(result.connections[0].groupPath == [PathComponent(name: "Team A", scope: nil, color: "Blue")])
        #expect(result.connections[0].tagNames == ["prod"])
        #expect(result.connections[0].credentialProfileRef == "p1")
        #expect(result.tags == [PlannedTag(name: "prod", color: "Red")])
        #expect(result.credentialProfiles == [
            PlannedCredentialProfile(ref: "p1", name: "reader", username: "ro", passwordMode: .prompt, secureFieldIds: [])
        ])
        #expect(result.keptConnections == ["c3": keptId])
    }

    @Test("The group path is clamped to the depth limit and keeps each group's color")
    func groupPathIsClamped() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(), groupRef: "g4")],
            groups: [
                BundleGroup(ref: "g1", name: "Client A", color: "Blue"),
                BundleGroup(ref: "g2", name: "  ", parentRef: "g1"),
                BundleGroup(ref: "g3", name: "Production", color: "Red", parentRef: "g2"),
                BundleGroup(ref: "g4", name: "EU", parentRef: "g3"),
                BundleGroup(ref: "g5", name: "Primary", parentRef: "g4")
            ]
        )
        let preview = Fixtures.makePreview(
            bundle,
            environment: Fixtures.makeEnvironment(rules: Fixtures.makeRules(maximumGroupDepth: 2))
        )

        #expect(plan(preview).connections.first?.groupPath == [
            PathComponent(name: "Client A", scope: nil, color: "Blue"),
            PathComponent(name: "Production", scope: nil, color: "Red")
        ])
    }

    @Test("Credentials ride with Add, As Copy and Replace, never with Keep Existing")
    func credentialsFollowWrittenConfiguration() throws {
        let duplicateId = UUID()
        let library = ImportLibrarySnapshot(connections: [
            Fixtures.existing(Fixtures.settings(host: "dup.example.com"), id: duplicateId)
        ])
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Add")),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Copy", host: "dup.example.com")),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "Replace", host: "dup.example.com")),
                BundleConnection(ref: "c4", settings: Fixtures.settings(name: "Keep", host: "dup.example.com")),
                BundleConnection(ref: "c5", settings: Fixtures.settings(name: "Unselected", host: "five"))
            ],
            credentials: [
                "c1": Fixtures.credentials(password: "one"),
                "c2": Fixtures.credentials(password: "two"),
                "c3": Fixtures.credentials(password: "three"),
                "c4": Fixtures.credentials(password: "four"),
                "c5": Fixtures.credentials(password: "five")
            ],
            savedQueries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c4")]
        )
        let preview = Fixtures.makePreview(bundle, library: library)

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c2", in: preview)
            selection.setSelected(true, connection: "c3", in: preview)
            selection.resolve("c3", as: .replace(duplicateId), in: preview)
            selection.setSelected(true, connection: "c4", in: preview)
            selection.setSelected(false, connection: "c5", in: preview)
        }

        #expect(result.connections.map(\.ref) == ["c1", "c2", "c3"])
        #expect(result.connections.map(\.credentials?.password) == ["one", "two", "three"])
        #expect(result.keptConnections == ["c4": duplicateId])
    }

    @Test("Startup SQL is dropped unless the user kept the commands")
    func startupCommandsAreDroppedUnlessKept() throws {
        var settings = Fixtures.settings(name: "Orders")
        settings.startupCommands = "SET search_path TO app;"
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: settings)])
        )
        let row = try #require(preview.connections.first)
        #expect(row.carriesStartupCommands)
        #expect(row.carriesCommands)

        #expect(try #require(plan(preview).connections.first).settings.startupCommands == nil)
        let kept = try #require(plan(preview) { $0.keepsCommands = true }.connections.first)
        #expect(kept.settings.startupCommands == "SET search_path TO app;")
    }

    @Test("A tunnel command is dropped unless the user kept it")
    func tunnelCommandIsDroppedUnlessKept() throws {
        var settings = Fixtures.settings(name: "Cluster Postgres", host: "db.internal")
        settings.tunnelCommand = ExportableTunnelCommand(
            method: "custom",
            command: "/usr/bin/forward --listen {port}",
            executablePath: nil,
            kubernetesNamespace: nil,
            kubernetesResource: nil,
            kubernetesContext: nil,
            awsTarget: nil,
            awsProfile: nil,
            awsRegion: nil
        )
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: settings)])
        )
        #expect(try #require(preview.connections.first).carriesTunnelCommand)

        let dropped = try #require(plan(preview).connections.first)
        #expect(dropped.settings.tunnelCommand == nil)
        #expect(dropped.settings.host == "db.internal")

        let kept = try #require(plan(preview) { $0.keepsCommands = true }.connections.first)
        #expect(kept.settings.tunnelCommand?.command == "/usr/bin/forward --listen {port}")
    }

    @Test("An imported profile asks for its password unless it reads pgpass")
    func profilePasswordModes() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "One"), credentialProfileRef: "p1"),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Two", host: "two"), credentialProfileRef: "p2"),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "Three", host: "three"), credentialProfileRef: "p1")
            ],
            credentialProfiles: [
                BundleCredentialProfile(ref: "p1", name: "pg", username: "app", passwordMode: .pgpass, secureFieldIds: ["token"]),
                BundleCredentialProfile(ref: "p2", name: "stored", username: "app", passwordMode: .stored)
            ]
        )
        let preview = Fixtures.makePreview(bundle)

        let result = plan(preview)

        #expect(result.credentialProfiles.map(\.ref) == ["p1", "p2"])
        #expect(result.credentialProfiles.map(\.passwordMode) == [.pgpass, .prompt])
        #expect(result.credentialProfiles[0].secureFieldIds == ["token"])
    }

    @Test("Without credential profile support no profile is planned or linked")
    func profilesOffWhenUnsupported() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(), credentialProfileRef: "p1")],
            credentialProfiles: [BundleCredentialProfile(ref: "p1", name: "pg", username: "app", passwordMode: .pgpass)]
        )
        let preview = Fixtures.makePreview(
            bundle,
            environment: Fixtures.makeEnvironment(rules: Fixtures.makeRules(supportsCredentialProfiles: false))
        )

        let result = plan(preview)

        #expect(result.credentialProfiles.isEmpty)
        #expect(result.connections.first?.credentialProfileRef == nil)
    }

    @Test("Tag names are trimmed and deduplicated ignoring case, with colors from the file")
    func tagsAreDeduplicated() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "One"), tagNames: [" Prod ", "prod", "", "EU"]),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Two", host: "two"), tagNames: ["PROD"])
            ],
            tags: [BundleTag(name: "prod", color: "Red")]
        )

        let result = plan(Fixtures.makePreview(bundle))

        #expect(result.connections.map(\.tagNames) == [["Prod", "EU"], ["PROD"]])
        #expect(result.tags == [PlannedTag(name: "Prod", color: "Red"), PlannedTag(name: "EU", color: nil)])
    }

    @Test("A plan with nothing to write is empty")
    func emptyPlan() throws {
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())])
        )

        #expect(!plan(preview).isEmpty)
        #expect(plan(preview) { $0.setSelected(false, connection: "c1", in: preview) }.isEmpty)
    }
}
