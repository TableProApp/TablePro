import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

struct IntentProjectScopeTests {
    private let directory: URL
    private let defaults: UserDefaults
    private let project = ConnectionProject(name: "Acme")
    private let group: ConnectionGroup
    private let grouped: DatabaseConnection
    private let loose: DatabaseConnection
    private let outside = DatabaseConnection(name: "Outside", type: .mysql)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.IntentProjects.\(UUID().uuidString)"))
        group = ConnectionGroup(name: "Production", projectId: project.id)
        grouped = DatabaseConnection(name: "Grouped", type: .mysql, groupId: group.id)
        loose = DatabaseConnection(name: "Loose", type: .mysql, projectId: project.id)
        try write([grouped, loose, outside], to: "connections.json")
    }

    private func write<Element: Encodable>(_ elements: [Element], to name: String) throws {
        try JSONEncoder().encode(elements).write(to: directory.appendingPathComponent(name))
    }

    private func activate(_ id: UUID) {
        defaults.set(id.uuidString, forKey: ConnectionLibraryPreferences.activeProjectKey)
    }

    @Test("The Shortcuts picker offers the active project's connections, through the group that carries the project")
    func suggestionsFollowTheActiveProject() throws {
        try write([group], to: "groups.json")
        try write([project], to: "projects.json")
        activate(project.id)

        let suggested = IntentConnectionLoader.suggested(in: directory, defaults: defaults)

        #expect(Set(suggested.map(\.id)) == [grouped.id, loose.id])
    }

    @Test("A connection named by id resolves whatever its project")
    func lookupByIdIsUnscoped() throws {
        try write([group], to: "groups.json")
        try write([project], to: "projects.json")
        activate(project.id)

        #expect(IntentConnectionLoader.load(in: directory).map(\.id).contains(outside.id))
    }

    @Test("With no active project, or one no project holds, the picker offers every connection")
    func noActiveProjectOffersEverything() throws {
        try write([group], to: "groups.json")
        try write([project], to: "projects.json")
        #expect(IntentConnectionLoader.suggested(in: directory, defaults: defaults).count == 3)

        activate(UUID())
        #expect(IntentConnectionLoader.suggested(in: directory, defaults: defaults).count == 3)
    }

    @Test("A groups or projects file that cannot be read hides nothing")
    func unreadableFilesOfferEverything() throws {
        try write([project], to: "projects.json")
        try Data("not json".utf8).write(to: directory.appendingPathComponent("groups.json"))
        activate(project.id)
        #expect(IntentConnectionLoader.suggested(in: directory, defaults: defaults).count == 3)

        try write([group], to: "groups.json")
        try Data("not json".utf8).write(to: directory.appendingPathComponent("projects.json"))
        #expect(IntentConnectionLoader.suggested(in: directory, defaults: defaults).count == 3)
    }
}
