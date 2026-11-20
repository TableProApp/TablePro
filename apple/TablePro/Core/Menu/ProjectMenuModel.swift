//
//  ProjectMenuModel.swift
//  TablePro
//

import AppKit

internal enum ProjectMenuEntry: Equatable {
    // Nil is All Connections.
    case scope(id: UUID?, title: String, isActive: Bool)
    case separator
    case newProject
    case manageProjects
}

// One list for the Welcome pop-up button and File > Project, so the two never disagree.
@MainActor
internal enum ProjectMenuModel {
    internal static var allConnectionsTitle: String { String(localized: "All Connections") }
    internal static var newProjectTitle: String { String(localized: "New Project…") }
    internal static var manageProjectsTitle: String { String(localized: "Manage Projects…") }

    internal static func entries(projects: [ConnectionProject], activeProjectId: UUID?) -> [ProjectMenuEntry] {
        let active = activeProjectId.flatMap { id in projects.contains { $0.id == id } ? id : nil }
        var entries: [ProjectMenuEntry] = [
            .scope(id: nil, title: allConnectionsTitle, isActive: active == nil),
        ]
        entries += projects.map { .scope(id: $0.id, title: $0.name, isActive: $0.id == active) }
        entries += [.separator, .newProject, .manageProjects]
        return entries
    }

    internal struct Actions {
        internal let select: Selector
        internal let newProject: Selector
        internal let manageProjects: Selector
    }

    // A scope row names its project in `representedObject`; All Connections carries none.
    internal static func items(for entries: [ProjectMenuEntry], actions: Actions, target: AnyObject?) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .scope(let id, let title, let isActive):
                let item = NSMenuItem(title: title, action: actions.select, keyEquivalent: "")
                item.target = target
                item.representedObject = id
                item.state = isActive ? .on : .off
                return item
            case .separator:
                return .separator()
            case .newProject:
                let item = NSMenuItem(title: newProjectTitle, action: actions.newProject, keyEquivalent: "")
                item.target = target
                return item
            case .manageProjects:
                let item = NSMenuItem(title: manageProjectsTitle, action: actions.manageProjects, keyEquivalent: "")
                item.target = target
                return item
            }
        }
    }
}

// File > Project, filled when it opens: the projects and the active one change while the menu is closed.
@MainActor
internal final class ProjectMenuDelegate: NSObject, NSMenuDelegate {
    private let projects: @MainActor () -> [ConnectionProject]
    private let activeProjectId: @MainActor () -> UUID?

    internal init(
        projects: @escaping @MainActor () -> [ConnectionProject] = { ProjectStorage.shared.loadProjects() },
        activeProjectId: @escaping @MainActor () -> UUID? = { ConnectionScope.shared.activeProjectId }
    ) {
        self.projects = projects
        self.activeProjectId = activeProjectId
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = ProjectMenuModel.entries(projects: projects(), activeProjectId: activeProjectId())
        let actions = ProjectMenuModel.Actions(
            select: #selector(AppDelegate.selectConnectionProject(_:)),
            newProject: #selector(AppDelegate.newConnectionProject(_:)),
            manageProjects: #selector(AppDelegate.manageConnectionProjects(_:))
        )
        for item in ProjectMenuModel.items(for: entries, actions: actions, target: nil) {
            menu.addItem(item)
        }
    }

    // No row carries a key equivalent, so a keystroke never needs the list built.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
