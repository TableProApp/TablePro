import Combine
import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct ProjectStorageTests {
    private let fixture: ProjectLibraryFixture
    private var projects: ProjectStorage { fixture.projects }

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    @Test("A new project is listed after the ones before it and marked to upload")
    func createListsAndMarks() throws {
        let acme = try projects.createProject(name: "  Acme  ", color: .blue, iconName: "briefcase")
        let globex = try projects.createProject(name: "Globex")

        #expect(projects.loadProjects().map(\.name) == ["Acme", "Globex"])
        #expect(projects.loadProjects().map(\.sortOrder) == [0, 1])
        #expect(projects.project(for: acme.id)?.color == .blue)
        #expect(fixture.dirty(.project) == [acme.id.uuidString, globex.id.uuidString])
    }

    @Test("An empty name is refused")
    func emptyNameRefused() {
        #expect(throws: ProjectStorageError.emptyName) {
            try projects.createProject(name: "   ")
        }
        #expect(projects.loadProjects().isEmpty)
    }

    @Test("A name that differs only in case, spacing or Unicode form is a duplicate")
    func duplicateNameRefused() throws {
        try projects.createProject(name: "Café")

        #expect(throws: ProjectStorageError.duplicateName("café")) {
            try projects.createProject(name: " café ")
        }
        #expect(throws: ProjectStorageError.duplicateName("Cafe\u{301}")) {
            try projects.createProject(name: "Cafe\u{301}")
        }
        #expect(projects.loadProjects().count == 1)
    }

    @Test("A rename keeps the project's own name free and refuses another project's")
    func renameValidates() throws {
        let acme = try projects.createProject(name: "Acme")
        try projects.createProject(name: "Globex")

        try projects.renameProject(id: acme.id, to: "ACME")
        #expect(projects.project(for: acme.id)?.name == "ACME")

        #expect(throws: ProjectStorageError.duplicateName("globex")) {
            try projects.renameProject(id: acme.id, to: "globex")
        }
        #expect(throws: ProjectStorageError.emptyName) {
            try projects.renameProject(id: acme.id, to: "")
        }
        #expect(throws: ProjectStorageError.projectNotFound) {
            try projects.renameProject(id: UUID(), to: "Other")
        }
        #expect(projects.project(for: acme.id)?.name == "ACME")
    }

    @Test("Reordering renumbers the list, with a project left out kept after the listed ones")
    func reorder() throws {
        let a = try projects.createProject(name: "A")
        let b = try projects.createProject(name: "B")
        let c = try projects.createProject(name: "C")

        try projects.reorderProjects([c.id, a.id])

        #expect(projects.loadProjects().map(\.id) == [c.id, a.id, b.id])
        #expect(projects.loadProjects().map(\.sortOrder) == [0, 1, 2])
    }

    @Test("Two projects of one name arriving from another device are both kept")
    func remoteDuplicateTolerated() throws {
        try projects.createProject(name: "Acme")
        let remote = ConnectionProject(name: "Acme", sortOrder: 5)

        #expect(projects.applyRemoteProject(remote) == .applied)
        #expect(projects.applyRemoteProject(remote) == .skipped)

        #expect(projects.loadProjects().map(\.name) == ["Acme", "Acme"])
    }

    @Test("Deleting a project keeps its groups and connections and takes them out of it")
    func deleteClearsMembership() throws {
        let acme = try projects.createProject(name: "Acme")
        let other = try projects.createProject(name: "Other")
        let group = try fixture.addGroup("Production", projectId: acme.id)
        let grouped = fixture.addConnection("grouped", groupId: group.id)
        let loose = fixture.addConnection("loose", projectId: acme.id)
        let localOnly = fixture.addConnection("local", projectId: acme.id, localOnly: true)
        let elsewhere = fixture.addConnection("elsewhere", projectId: other.id)
        fixture.clearDirty()

        try projects.deleteProject(id: acme.id)

        #expect(projects.loadProjects().map(\.id) == [other.id])
        #expect(fixture.groups.group(for: group.id)?.projectId == nil)
        #expect(fixture.stored(grouped)?.groupId == group.id)
        #expect(fixture.stored(loose)?.projectId == nil)
        #expect(fixture.stored(localOnly)?.projectId == nil)
        #expect(fixture.stored(elsewhere)?.projectId == other.id)
        #expect(fixture.tombstones(.project) == [acme.id.uuidString])
        #expect(fixture.dirty(.connection) == [loose.id.uuidString])
        #expect(fixture.dirty(.group) == [group.id.uuidString])
    }

    @Test("A project whose groups cannot be saved is kept, with no tombstone sent")
    func deleteReportsAMembershipFailure() throws {
        let acme = try projects.createProject(name: "Acme")
        try fixture.addGroup("Production", projectId: acme.id)
        fixture.defaults.set(Data("not json".utf8), forKey: "com.TablePro.groups")
        let unreadableGroups = GroupStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            appEvents: fixture.appEvents
        )
        let storage = ProjectStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            groupStorage: unreadableGroups,
            appEvents: fixture.appEvents
        )

        #expect(throws: ProjectStorageError.membershipNotSaved) {
            try storage.deleteProject(id: acme.id)
        }
        #expect(storage.project(for: acme.id) != nil)
        #expect(fixture.tombstones(.project).isEmpty)
    }

    @Test("A deletion another device made clears the members and sends no tombstone")
    func remoteDeletionClearsMembership() throws {
        let acme = try projects.createProject(name: "Acme")
        let group = try fixture.addGroup("Production", projectId: acme.id)
        let loose = fixture.addConnection("loose", projectId: acme.id, localOnly: true)

        #expect(projects.applyRemoteDeletions([acme.id]))

        #expect(projects.loadProjects().isEmpty)
        #expect(fixture.groups.group(for: group.id)?.projectId == nil)
        #expect(fixture.stored(loose)?.projectId == nil)
        #expect(fixture.tombstones(.project).isEmpty)
    }

    @Test("Moving connections to a project takes a grouped one out of another project's group")
    func moveConnectionsToProject() throws {
        let acme = try projects.createProject(name: "Acme")
        let globex = try projects.createProject(name: "Globex")
        let group = try fixture.addGroup("Production", projectId: acme.id)
        let grouped = fixture.addConnection("grouped", groupId: group.id)
        let loose = fixture.addConnection("loose")
        let already = fixture.addConnection("already", groupId: group.id)

        #expect(projects.moveConnections([grouped.id, loose.id], toProject: globex.id))
        #expect(projects.moveConnections([already.id], toProject: acme.id))

        #expect(fixture.stored(grouped)?.groupId == nil)
        #expect(fixture.stored(grouped)?.projectId == globex.id)
        #expect(fixture.stored(loose)?.projectId == globex.id)
        #expect(fixture.stored(already)?.groupId == group.id)
        #expect(fixture.stored(already)?.projectId == nil)
    }

    @Test("Moving a group to a project roots a nested one and refuses a name the project already has")
    func moveGroupsToProject() throws {
        let acme = try projects.createProject(name: "Acme")
        let globex = try projects.createProject(name: "Globex")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let nested = try fixture.addGroup("Europe", parentId: production.id)
        try fixture.addGroup("Production", projectId: globex.id)

        try projects.moveGroups([nested.id], toProject: globex.id)
        #expect(fixture.groups.group(for: nested.id)?.parentId == nil)
        #expect(fixture.groups.group(for: nested.id)?.projectId == globex.id)

        #expect(throws: GroupStorageError.duplicateName("Production")) {
            try projects.moveGroups([production.id], toProject: globex.id)
        }
        #expect(fixture.groups.group(for: production.id)?.projectId == acme.id)
    }

    @Test("A payload with one entry this build cannot read keeps the others")
    func salvagesReadableEntries() throws {
        let id = UUID()
        let payload = #"[{"id":"\#(id.uuidString)","name":"Acme"},{"name":"no id"}]"#
        fixture.defaults.set(Data(payload.utf8), forKey: "com.TablePro.projects")
        let storage = ProjectStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            groupStorage: fixture.groups,
            appEvents: fixture.appEvents
        )

        #expect(storage.loadProjects() == [ConnectionProject(id: id, name: "Acme")])
        #expect(!storage.storeIsUnreadable)
    }

    @Test("A payload that cannot be read at all is never written over")
    func unreadableStoreRefusesWrites() throws {
        fixture.defaults.set(Data("not json".utf8), forKey: "com.TablePro.projects")
        let storage = ProjectStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            groupStorage: fixture.groups,
            appEvents: fixture.appEvents
        )

        #expect(storage.loadProjects().isEmpty)
        #expect(throws: ProjectStorageError.storeUnreadable) {
            try storage.createProject(name: "Acme")
        }
        #expect(fixture.defaults.data(forKey: "com.TablePro.projects") == Data("not json".utf8))
    }

    @Test("An import matches a project by id, then by name, and makes the rest")
    func ensureProjects() throws {
        let acme = try projects.createProject(name: "Acme")
        let renamed = try projects.createProject(name: "Renamed here")
        let newId = UUID()

        let ids = try projects.ensureProjects([
            PlannedProject(ref: BundleRef("p1"), id: nil, name: "acme", color: nil, iconName: nil),
            PlannedProject(ref: BundleRef("p2"), id: renamed.id, name: "Old name", color: nil, iconName: nil),
            PlannedProject(ref: BundleRef("p3"), id: newId, name: "Initech", color: "Blue", iconName: nil),
        ])

        #expect(ids[BundleRef("p1")] == acme.id)
        #expect(ids[BundleRef("p2")] == renamed.id)
        #expect(ids[BundleRef("p3")] == newId)
        #expect(projects.loadProjects().map(\.name) == ["Acme", "Renamed here", "Initech"])
        #expect(projects.project(for: newId)?.color == .blue)
    }

    @Test("A change to the project list is announced once per edit")
    func announcesChanges() throws {
        var count = 0
        let subscription = fixture.appEvents.connectionUpdated.sink { _ in count += 1 }
        defer { subscription.cancel() }

        let acme = try projects.createProject(name: "Acme")
        try projects.renameProject(id: acme.id, to: "Acme")
        try projects.deleteProject(id: acme.id)

        #expect(count == 2)
    }

    // MARK: - A record this build cannot read

    private static let unreadableId = UUID()
    private static let unreadableJSON =
        #"{"id":"\#(unreadableId.uuidString)","name":7,"shape":2,"extra":{"kept":[1,2.5,null,"text"]}}"#

    // A fresh store over a payload holding one readable project and one this build cannot decode.
    private func storageHoldingAnUnreadableProject() throws -> (storage: ProjectStorage, readable: ConnectionProject) {
        let readable = ConnectionProject(name: "Acme")
        let encoded = String(decoding: try JSONEncoder().encode(readable), as: UTF8.self)
        fixture.defaults.set(Data("[\(encoded),\(Self.unreadableJSON)]".utf8), forKey: "com.TablePro.projects")
        let storage = ProjectStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            groupStorage: fixture.groups,
            appEvents: fixture.appEvents
        )
        return (storage, readable)
    }

    private func storedRows() throws -> [NSDictionary] {
        let data = try #require(fixture.defaults.data(forKey: "com.TablePro.projects"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [NSDictionary])
    }

    private func unreadableRow() throws -> NSDictionary? {
        try storedRows().first { $0["id"] as? String == Self.unreadableId.uuidString }
    }

    private var originalRow: NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(Self.unreadableJSON.utf8)) as? NSDictionary
    }

    @Test("A project this build cannot read is kept as it was through a create, rename, reorder and delete of others")
    func unreadableRecordSurvivesEdits() throws {
        let (storage, acme) = try storageHoldingAnUnreadableProject()
        #expect(storage.loadProjects().map(\.id) == [acme.id])
        #expect(storage.unreadableProjectIds == [Self.unreadableId])
        #expect(!storage.storeIsUnreadable)

        let globex = try storage.createProject(name: "Globex")
        #expect(try unreadableRow() == originalRow)

        try storage.renameProject(id: acme.id, to: "Acme Corp")
        #expect(try unreadableRow() == originalRow)

        try storage.reorderProjects([globex.id, acme.id])
        #expect(try unreadableRow() == originalRow)

        try storage.deleteProject(id: acme.id)
        #expect(try unreadableRow() == originalRow)

        #expect(storage.loadProjects().map(\.id) == [globex.id])
        #expect(try storedRows().count == 2)
        #expect(storage.unreadableProjectIds == [Self.unreadableId])
        #expect(!fixture.dirty(.project).contains(Self.unreadableId.uuidString))
    }

    @Test("The id of a project this build cannot read is taken: a save, a pulled record and an import cannot use it")
    func unreadableIdIsRefused() throws {
        let (storage, acme) = try storageHoldingAnUnreadableProject()
        let impostor = ConnectionProject(id: Self.unreadableId, name: "Impostor")

        #expect(!storage.saveProjects([acme, impostor]))
        #expect(storage.applyRemoteProject(impostor) == .failed)
        #expect(throws: ProjectStorageError.projectNotFound) {
            try storage.renameProject(id: Self.unreadableId, to: "Renamed")
        }

        let ids = try storage.ensureProjects([
            PlannedProject(ref: BundleRef("p1"), id: Self.unreadableId, name: "Initech", color: nil, iconName: nil),
        ])
        let imported = try #require(ids[BundleRef("p1")])

        #expect(imported != Self.unreadableId)
        #expect(storage.loadProjects().map(\.name) == ["Acme", "Initech"])
        #expect(try unreadableRow() == originalRow)
        #expect(try storedRows().count == 3)
    }

    @Test("A deletion another device made removes a project this build cannot read by its id")
    func remoteDeletionRemovesAnUnreadableProject() throws {
        let (storage, acme) = try storageHoldingAnUnreadableProject()
        let member = fixture.addConnection("member", projectId: Self.unreadableId)

        #expect(storage.applyRemoteDeletions([Self.unreadableId]))

        #expect(try unreadableRow() == nil)
        #expect(storage.unreadableProjectIds.isEmpty)
        #expect(storage.loadProjects().map(\.id) == [acme.id])
        #expect(fixture.stored(member)?.projectId == nil)
        #expect(fixture.tombstones(.project).isEmpty)
    }
}
