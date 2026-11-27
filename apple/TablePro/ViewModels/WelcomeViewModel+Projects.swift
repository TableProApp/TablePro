//
//  WelcomeViewModel+Projects.swift
//  TablePro
//

import Foundation

extension WelcomeViewModel {
    // Nil is All Connections.
    func selectProject(_ projectId: UUID?) {
        scope.setActiveProject(projectId)
    }

    // The search text stays, so the same search runs over every connection.
    func searchAllConnections() {
        selectProject(nil)
    }

    func requestNewProject() {
        activeSheet = .newProject
    }

    func requestManageProjects() {
        activeSheet = .manageProjects
    }

    // Asked for from the scope control, so the list moves to the project it made.
    func createProject(name: String) throws {
        let project = try projectStorage.createProject(name: name)
        selectProject(project.id)
        loadConnections()
    }

    func moveToProject(
        connectionIds: [UUID],
        groupIds: [UUID],
        projectId: UUID?,
        undoManager: UndoManager?
    ) {
        performUndoable(String(localized: "Move to Project"), undoManager: undoManager) {
            if !connectionIds.isEmpty, !projectStorage.moveConnections(connectionIds, toProject: projectId) {
                reportLibraryWriteFailure()
                return
            }
            guard !groupIds.isEmpty else { return }
            do {
                try projectStorage.moveGroups(groupIds, toProject: projectId)
            } catch {
                libraryErrorMessage = error.localizedDescription
            }
        }
    }
}

extension WelcomeViewModel {
    // The active project's groups, or every group when the one being edited sits outside it.
    func groupChoices(editing group: ConnectionGroup) -> [ConnectionGroup] {
        scopedGroups.contains { $0.id == group.id } ? scopedGroups : groups
    }
}
