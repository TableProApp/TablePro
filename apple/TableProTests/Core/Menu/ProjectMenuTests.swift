import AppKit
@testable import TablePro
import Testing

@MainActor
struct ProjectMenuTests {
    private let acme = ConnectionProject(name: "Acme", sortOrder: 0)
    private let globex = ConnectionProject(name: "Globex", sortOrder: 1)

    private func fileMenu() throws -> NSMenu {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings())
        return try #require(built.bar.items.first { $0.title == String(localized: "File") }?.submenu)
    }

    private func filled(projects: [ConnectionProject], active: UUID?) -> NSMenu {
        let delegate = ProjectMenuDelegate(projects: { projects }, activeProjectId: { active })
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        return menu
    }

    @Test("With no projects the list is All Connections, checked, over the two commands")
    func noProjects() {
        let entries = ProjectMenuModel.entries(projects: [], activeProjectId: nil)

        #expect(entries == [
            .scope(id: nil, title: "All Connections", isActive: true),
            .separator,
            .newProject,
            .manageProjects,
        ])
    }

    @Test("All Connections leads, the projects follow in order, and only the active one is checked")
    func activeProject() {
        let entries = ProjectMenuModel.entries(projects: [acme, globex], activeProjectId: globex.id)

        #expect(entries == [
            .scope(id: nil, title: "All Connections", isActive: false),
            .scope(id: acme.id, title: "Acme", isActive: false),
            .scope(id: globex.id, title: "Globex", isActive: true),
            .separator,
            .newProject,
            .manageProjects,
        ])
    }

    @Test("An active project that is gone checks All Connections")
    func unknownActiveProject() {
        let entries = ProjectMenuModel.entries(projects: [acme], activeProjectId: UUID())

        #expect(entries.first == .scope(id: nil, title: "All Connections", isActive: true))
        #expect(entries.contains(.scope(id: acme.id, title: "Acme", isActive: false)))
    }

    @Test("File > Project sits with the connection commands, apart from Open Project Folder…")
    func fileMenuPlacement() throws {
        let file = try fileMenu()
        let titles = file.items.map(\.title)
        let project = try #require(titles.firstIndex(of: "Project"))
        let manage = try #require(titles.firstIndex(of: "Manage Connections"))

        #expect(project == manage + 1)
        #expect(file.items[project + 1].isSeparatorItem)
        #expect(file.items[project].submenu?.delegate is ProjectMenuDelegate)
        #expect(file.items[project].submenu?.items.isEmpty == true)
        #expect(!titles.contains("Open Project Folder…"))
        let importMenu = try #require(file.items.first { $0.title == "Import" }?.submenu)
        #expect(importMenu.items.contains { $0.title == "Open Project Folder…" })
    }

    @Test("The submenu is filled when it opens, with the check on the project active then")
    func filledOnOpen() {
        var active: UUID? = acme.id
        let delegate = ProjectMenuDelegate(projects: { [self.acme, self.globex] }, activeProjectId: { active })
        let menu = NSMenu()

        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["All Connections", "Acme", "Globex", "", "New Project…", "Manage Projects…"])
        #expect(menu.items.map(\.state) == [.off, .on, .off, .off, .off, .off])

        active = nil
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.count == 6)
        #expect(menu.items.map(\.state) == [.on, .off, .off, .off, .off, .off])
    }

    @Test("A row names its project and leaves the responder chain to carry it out, with no key equivalent")
    func rowsCarryTheirProject() {
        let menu = filled(projects: [acme], active: nil)

        #expect(menu.items[0].representedObject == nil)
        #expect(menu.items[1].representedObject as? UUID == acme.id)
        #expect(menu.items[0].action == #selector(AppDelegate.selectConnectionProject(_:)))
        #expect(menu.items[1].action == #selector(AppDelegate.selectConnectionProject(_:)))
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].action == #selector(AppDelegate.newConnectionProject(_:)))
        #expect(menu.items[4].action == #selector(AppDelegate.manageConnectionProjects(_:)))
        #expect(menu.items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty })
    }

    @Test("The pop-up button shows the active scope, and goes back to it after a command row")
    func popUpButtonShowsTheActiveScope() throws {
        var selected: [UUID?] = []
        var newProjectCount = 0
        let coordinator = ProjectPopUpButton.Coordinator(actions: ProjectPopUpActions(
            select: { selected.append($0) },
            newProject: { newProjectCount += 1 },
            manageProjects: {}
        ))
        let button = NSPopUpButton(frame: .zero, pullsDown: false)

        coordinator.apply(ProjectMenuModel.entries(projects: [acme, globex], activeProjectId: globex.id), to: button)
        #expect(button.titleOfSelectedItem == "Globex")
        #expect(button.itemTitles == ["All Connections", "Acme", "Globex", "", "New Project…", "Manage Projects…"])

        let newProject = try #require(button.item(withTitle: "New Project…"))
        button.select(newProject)
        coordinator.newProject(newProject)
        #expect(newProjectCount == 1)
        #expect(button.titleOfSelectedItem == "Globex")

        let acmeRow = try #require(button.item(withTitle: "Acme"))
        coordinator.selectScope(acmeRow)
        #expect(selected == [acme.id])

        coordinator.apply(ProjectMenuModel.entries(projects: [], activeProjectId: nil), to: button)
        #expect(button.titleOfSelectedItem == "All Connections")
        #expect(button.itemTitles == ["All Connections", "", "New Project…", "Manage Projects…"])
    }

    @Test("File > Project checks the scope in force each time it opens: after a switch and after the active project is deleted")
    func submenuFollowsTheScope() throws {
        let fixture = try ProjectLibraryFixture()
        let stored = try fixture.projects.createProject(name: "Acme")
        let delegate = ProjectMenuDelegate(
            projects: { fixture.projects.loadProjects() },
            activeProjectId: { fixture.scope.activeProjectId }
        )
        let menu = NSMenu()
        func checked() -> [String] {
            delegate.menuNeedsUpdate(menu)
            return menu.items.filter { $0.state == .on }.map(\.title)
        }

        #expect(checked() == ["All Connections"])
        fixture.scope.setActiveProject(stored.id)
        #expect(checked() == ["Acme"])
        try fixture.projects.deleteProject(id: stored.id)
        #expect(checked() == ["All Connections"])
        #expect(menu.items.map(\.title).contains("Acme") == false)
    }
}
