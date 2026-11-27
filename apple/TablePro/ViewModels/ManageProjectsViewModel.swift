//
//  ManageProjectsViewModel.swift
//  TablePro
//

import Combine
import Foundation
import SwiftUI
import TableProConnectionLibrary

@MainActor
internal final class ManageProjectsViewModel: ObservableObject {
    @Published private(set) var projects: [ConnectionProject] = []
    @Published var selection: UUID?
    @Published var errorMessage: String?
    @Published var projectPendingDeletion: ConnectionProject?

    private let storage: ProjectStorage
    private var changeCancellable: AnyCancellable?

    internal init(storage: ProjectStorage = .shared, appEvents: AppEvents = .shared) {
        self.storage = storage
        reload()
        // A project made, renamed or deleted elsewhere, or by a sync pull, sends this.
        changeCancellable = appEvents.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    internal func reload() {
        let stored = storage.loadProjects()
        if projects != stored {
            projects = stored
        }
        if let selection, !stored.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    internal var selectedProject: ConnectionProject? {
        selection.flatMap { id in projects.first { $0.id == id } }
    }

    // Made with a free name, so the row can be renamed in place straight away.
    @discardableResult
    internal func addProject() -> UUID? {
        errorMessage = nil
        do {
            let project = try storage.createProject(name: Self.unusedName(among: storage.loadProjects()))
            reload()
            selection = project.id
            return project.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // False leaves the stored name as it was and says why in `errorMessage`.
    @discardableResult
    internal func rename(_ id: UUID, to name: String) -> Bool {
        do {
            try storage.renameProject(id: id, to: name)
            errorMessage = nil
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    internal func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = projects.map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try storage.reorderProjects(ordered)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    internal func requestDeleteSelection() {
        projectPendingDeletion = selectedProject
    }

    internal func confirmDelete() {
        guard let project = projectPendingDeletion else { return }
        projectPendingDeletion = nil
        do {
            try storage.deleteProject(id: project.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    internal static func unusedName(among projects: [ConnectionProject]) -> String {
        let base = String(localized: "New Project")
        guard LibraryProjectName.match(base, in: projects) != nil else { return base }
        var number = 2
        while true {
            let candidate = String(format: String(localized: "New Project %d"), number)
            if LibraryProjectName.match(candidate, in: projects) == nil { return candidate }
            number += 1
        }
    }
}
