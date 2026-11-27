//
//  ProjectStorage.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProImport
import TableProSyncTransport

internal enum ProjectStorageError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case projectNotFound
    case storeUnreadable
    case membershipNotSaved

    internal var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "A project needs a name.")
        case .duplicateName(let name):
            return String(format: String(localized: "A project named “%@” already exists."), name)
        case .projectNotFound:
            return String(localized: "That project no longer exists.")
        case .storeUnreadable:
            return String(localized: "The saved projects could not be read. Nothing was changed.")
        case .membershipNotSaved:
            return String(localized: "The connections and groups of this project could not be saved. Nothing was changed.")
        }
    }
}

@MainActor
internal final class ProjectStorage {
    internal static let shared = ProjectStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ProjectStorage")
    private let syncJournal: SyncHostJournal
    private let connectionStorageProvider: () -> ConnectionStorage
    private let groupStorageProvider: () -> GroupStorage
    private let appEvents: AppEvents
    // Every write rewrites the whole library, so one that could not be read is never written over.
    internal private(set) var storeIsUnreadable = false

    internal init(
        syncJournal: SyncHostJournal = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        groupStorage: @escaping @autoclosure () -> GroupStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.syncJournal = syncJournal
        self.connectionStorageProvider = connectionStorage
        self.groupStorageProvider = groupStorage
        self.appEvents = appEvents
    }

    // MARK: - Reading

    // In display order.
    internal func loadProjects() -> [ConnectionProject] {
        guard let image = connectionStorageProvider().library.current() else {
            Self.logger.error("The connection library could not be read; leaving the projects untouched")
            storeIsUnreadable = true
            return []
        }
        storeIsUnreadable = false
        return Self.ordered(image.projects)
    }

    internal func project(for id: UUID) -> ConnectionProject? {
        loadProjects().first { $0.id == id }
    }

    internal var projectIds: Set<UUID> {
        Set(loadProjects().map(\.id))
    }

    // MARK: - Writing

    @discardableResult
    internal func saveProjects(_ projects: [ConnectionProject]) -> Bool {
        let previous = loadProjects()
        let library = connectionStorageProvider().library
        guard !storeIsUnreadable, var image = library.current() else {
            Self.logger.error("Refusing to overwrite an unreadable project store")
            return false
        }
        image.projects = projects
        guard library.commit(image, byUser: false) else {
            Self.logger.error("Failed to save projects")
            return false
        }
        syncJournal.recorded(.project, written: SyncRecordChanges.changedIds(from: previous, to: projects))
        return true
    }

    @discardableResult
    internal func createProject(
        name: String,
        color: ConnectionColor = .none,
        iconName: String? = nil
    ) throws -> ConnectionProject {
        var projects = loadProjects()
        guard !storeIsUnreadable else { throw ProjectStorageError.storeUnreadable }
        let project = ConnectionProject(
            name: try validatedName(name, among: projects, excluding: nil),
            color: color,
            iconName: LibrarySymbolCatalog.normalizedName(iconName),
            sortOrder: LibraryOrdering.nextSortOrder(after: projects.map(\.sortOrder))
        )
        projects.append(project)
        guard saveProjects(projects) else { throw ProjectStorageError.storeUnreadable }
        notifyChanged()
        return project
    }

    internal func renameProject(id: UUID, to name: String) throws {
        try updateProject(id: id) { $0.name = name }
    }

    internal func updateProject(id: UUID, _ mutate: (inout ConnectionProject) -> Void) throws {
        var projects = loadProjects()
        guard !storeIsUnreadable else { throw ProjectStorageError.storeUnreadable }
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectStorageError.projectNotFound
        }
        var updated = projects[index]
        mutate(&updated)
        updated.iconName = LibrarySymbolCatalog.normalizedName(updated.iconName)
        if updated.name != projects[index].name {
            updated.name = try validatedName(updated.name, among: projects, excluding: id)
        }
        guard updated != projects[index] else { return }
        projects[index] = updated
        guard saveProjects(projects) else { throw ProjectStorageError.storeUnreadable }
        notifyChanged()
    }

    // The listed ids lead in the order given; any project left out keeps its place after them.
    internal func reorderProjects(_ orderedIds: [UUID]) throws {
        var projects = loadProjects()
        guard !storeIsUnreadable else { throw ProjectStorageError.storeUnreadable }
        let known = Set(projects.map(\.id))
        var seen: Set<UUID> = []
        let leading = orderedIds.filter { known.contains($0) && seen.insert($0).inserted }
        let order = leading + projects.map(\.id).filter { !seen.contains($0) }
        let ranks = LibraryOrdering.ranks(for: order)
        for index in projects.indices {
            projects[index].sortOrder = ranks[projects[index].id] ?? projects[index].sortOrder
        }
        guard saveProjects(projects) else { throw ProjectStorageError.storeUnreadable }
        notifyChanged()
    }

    // Its groups and connections stay and leave the project. They are saved before the project goes, and
    // the tombstone follows the last write, so a sync it starts reads the finished state.
    internal func deleteProject(id: UUID) throws {
        var projects = loadProjects()
        guard !storeIsUnreadable else { throw ProjectStorageError.storeUnreadable }
        guard projects.contains(where: { $0.id == id }) else { throw ProjectStorageError.projectNotFound }
        guard clearMembership(of: [id]) else { throw ProjectStorageError.membershipNotSaved }

        projects.removeAll { $0.id == id }
        guard saveProjects(projects) else { throw ProjectStorageError.storeUnreadable }
        syncJournal.recorded(.project, deleted: [id.uuidString])
        notifyChanged()
    }

    // MARK: - Membership

    // A connection in a group of another project leaves the group, since only its top-level group carries a project.
    @discardableResult
    internal func moveConnections(_ ids: [UUID], toProject projectId: UUID?) -> Bool {
        let storage = connectionStorageProvider()
        let connections = storage.loadConnections()
        let scope = LibraryProjectScope(groups: groupStorageProvider().loadGroups(), projectIds: projectIds)
        let target = scope.resolved(projectId)
        let moving = Set(ids)
        var nextRootOrder = ConnectionStorage.nextSortOrder(in: connections, groupId: nil)
        let saved = storage.rewriteMembership(byUser: false) { connection in
            guard moving.contains(connection.id), scope.effectiveProjectId(of: connection) != target else { return }
            if connection.groupId != nil {
                connection.groupId = nil
                connection.sortOrder = nextRootOrder
                nextRootOrder += 1
            }
            connection.projectId = target
        }
        guard saved else { return false }
        notifyChanged()
        return true
    }

    internal func moveGroups(_ ids: [UUID], toProject projectId: UUID?) throws {
        try groupStorageProvider().moveGroups(ids, toProject: projectId)
    }

    // MARK: - Import

    internal func ensureProjects(_ planned: [PlannedProject]) throws -> [BundleRef: UUID] {
        guard !planned.isEmpty else { return [:] }
        var projects = loadProjects()
        guard !storeIsUnreadable else { throw ProjectStorageError.storeUnreadable }
        let resolved = ImportProjectResolver.resolve(planned, existing: projects, takenIds: [])
        guard !resolved.created.isEmpty else { return resolved.ids }
        for created in resolved.created {
            projects.append(ConnectionProject(
                id: created.id,
                name: created.name,
                color: created.color.map(ConnectionColor.init(storedValue:)) ?? .none,
                iconName: created.iconName,
                sortOrder: created.sortOrder
            ))
        }
        guard saveProjects(projects) else { throw ProjectStorageError.storeUnreadable }
        notifyChanged()
        return resolved.ids
    }

    // MARK: - Private

    private func clearMembership(of ids: Set<UUID>) -> Bool {
        let connectionStorage = connectionStorageProvider()
        let groupStorage = groupStorageProvider()
        let connections = connectionStorage.loadConnections()
        let groups = groupStorage.loadGroups()
        guard !groupStorage.storeIsUnreadable else { return false }

        var changes = LibraryProjectChanges()
        for id in ids {
            let cleared = LibraryProjectNormalizer.deletingProject(id, connections: connections, groups: groups)
            changes.connections.merge(cleared.connections) { _, latest in latest }
            changes.groups.merge(cleared.groups) { _, latest in latest }
        }
        guard !changes.isEmpty else { return true }
        if !changes.connections.isEmpty {
            guard !connectionStorage.isLibraryUnreadable else { return false }
            let saved = connectionStorage.rewriteMembership(byUser: false) { connection in
                connection.projectId = changes.connectionProjectId(connection.id, current: connection.projectId)
            }
            guard saved else {
                Self.logger.error("Kept a project: its connections could not be saved without it")
                return false
            }
        }
        guard groupStorage.applyProjectChanges(changes.groups) else {
            Self.logger.error("Kept a project: its groups could not be saved without it")
            return false
        }
        return true
    }

    private func validatedName(
        _ name: String,
        among projects: [ConnectionProject],
        excluding id: UUID?
    ) throws -> String {
        let trimmed = LibraryProjectName.trimmed(name)
        switch LibraryProjectName.problem(trimmed, among: projects, excluding: id) {
        case .empty:
            throw ProjectStorageError.emptyName
        case .duplicate:
            throw ProjectStorageError.duplicateName(trimmed)
        case nil:
            return trimmed
        }
    }

    // Projects sit in the Welcome list's scope control, which reloads on this event.
    private func notifyChanged() {
        appEvents.connectionUpdated.send(nil)
    }

    private static func ordered(_ projects: [ConnectionProject]) -> [ConnectionProject] {
        projects.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortOrder < rhs.sortOrder
        }
    }
}
