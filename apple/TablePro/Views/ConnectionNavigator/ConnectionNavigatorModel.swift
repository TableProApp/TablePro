//
//  ConnectionNavigatorModel.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import TableProConnectionLibrary

/// How the navigator opens a connection. The router picks the window, so the navigator never adopts
/// a workspace itself and never hosts a connection twice.
@MainActor
internal protocol ConnectionNavigatorRouting: AnyObject {
    func route(_ intent: LaunchIntent) async throws
    func openConnectionPreferringNewWindow(id: UUID) async throws
}

extension TabRouter: ConnectionNavigatorRouting {}

/// What the navigator reads from the rest of the app, gathered so a test can hand it a library of
/// its own, its own events and a router that records instead of opening windows.
@MainActor
internal struct ConnectionNavigatorEnvironment {
    internal var appEvents: AppEvents = .shared
    internal var connectionStorage: ConnectionStorage = .shared
    internal var groupStorage: GroupStorage = .shared
    internal var listPreferences: ConnectionListPreferences = .shared
    internal var recentConnections: RecentConnectionsStore = .shared
    internal var expansionStore = ConnectionNavigatorExpansionStore()
    internal var router: any ConnectionNavigatorRouting = TabRouter.shared
    internal var status: (UUID) -> ConnectionDisplayStatus = { ConnectionStatusResolver.status(for: $0) }
    internal var holdsSession: (UUID) -> Bool = { DatabaseManager.shared.session(for: $0) != nil }
    internal var hostedConnectionIds: () -> Set<UUID> = { WindowManager.shared.allConnectionIds() }
    internal var canMoveToNewWindow: (UUID) -> Bool = { WindowManager.shared.canMoveToNewWindow(connectionId: $0) }
    internal var isDriverRejected: (DatabaseConnection) -> Bool = { connection in
        let typeId = connection.type.pluginTypeId
        return PluginManager.shared.rejectedPlugins.contains { $0.providedDatabaseTypeIds.contains(typeId) }
    }
}

/// The navigator's rows and what a click on one does.
///
/// The rows are built from storage on every library change, never patched from a cache of it, the
/// same rule the Welcome list keeps (`.claude/rules/welcome-library.md`). A status or a window
/// moving only re-marks the rows it touches, so a connect in progress does not rebuild the list.
@MainActor
internal final class ConnectionNavigatorModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionNavigator")

    /// The window drawing the navigator, which is the only one that can say which connection is on
    /// screen and which ones a click can switch to.
    internal weak var host: (any WorkspaceRailHost)?
    internal var onOpenFailure: ((Error) -> Void)?

    @Published internal private(set) var rows: [ConnectionNavigatorRow] = []
    @Published internal private(set) var revision = 0
    @Published internal private(set) var presentationRevision = 0
    internal private(set) var isLibraryEmpty = true
    internal private(set) var groups: [ConnectionGroup] = []

    internal var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            rebuild()
        }
    }

    private let environment: ConnectionNavigatorEnvironment
    private var connections: [DatabaseConnection] = []
    private var expandedGroupIds: Set<UUID> = []
    private var hasLoadedExpansion = false
    private var cancellables: Set<AnyCancellable> = []

    internal init(environment: ConnectionNavigatorEnvironment = ConnectionNavigatorEnvironment()) {
        self.environment = environment
    }

    internal var isFiltering: Bool {
        !LibraryQuery(text: filterText).trimmedText.isEmpty
    }

    internal var shownConnectionId: UUID? {
        host?.selectedConnectionId
    }

    // MARK: - Lifecycle

    /// Called each time the list comes on screen. A list that was away missed every event, so it
    /// rebuilds whether or not it was already listening.
    internal func start() {
        if cancellables.isEmpty {
            let events = environment.appEvents
            Publishers.Merge(events.connectionUpdated.map { _ in () }, events.connectionListStateChanged)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.rebuild() }
                .store(in: &cancellables)
            // The mark reads the session and the window phase, and placement reads which window
            // hosts what; none of them is observable, so each of their events re-marks the rows.
            Publishers.Merge3(
                events.connectionStatusChanged.map { _ in () },
                events.connectionPhaseChanged.map { _ in () },
                events.connectionWindowsChanged
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshPresentation() }
            .store(in: &cancellables)
        }
        rebuild()
    }

    internal func stop() {
        cancellables.removeAll()
    }

    // MARK: - Rows

    internal func rebuild() {
        connections = environment.connectionStorage.loadConnections()
        groups = environment.groupStorage.loadGroups()
        let groupIds = Set(groups.map(\.id))
        if hasLoadedExpansion {
            expandedGroupIds.formIntersection(groupIds)
        } else {
            expandedGroupIds = environment.expansionStore.load(keeping: groupIds)
            hasLoadedExpansion = true
        }
        isLibraryEmpty = connections.isEmpty

        let presentation = presentationMaps()
        rows = ConnectionNavigatorRowsBuilder.build(ConnectionNavigatorRowsInput(
            connections: connections,
            groups: groups,
            sortMode: environment.listPreferences.sortMode,
            lastConnected: environment.recentConnections.lastConnected,
            filterText: filterText,
            expandedGroupIds: expandedGroupIds,
            statuses: presentation.statuses,
            placements: presentation.placements,
            driverRejectedIds: Set(connections.filter(environment.isDriverRejected).map(\.id))
        ))
        revision += 1
    }

    internal func refreshPresentation() {
        let presentation = presentationMaps()
        let updated = ConnectionNavigatorRowsBuilder.applying(
            statuses: presentation.statuses,
            placements: presentation.placements,
            to: rows
        )
        guard updated != rows else { return }
        rows = updated
        presentationRevision += 1
    }

    private func presentationMaps() -> (
        statuses: [UUID: ConnectionDisplayStatus],
        placements: [UUID: ConnectionNavigatorPlacement]
    ) {
        let hostedHere = Set(host?.hostedConnectionIds ?? [])
        let hostedAnywhere = environment.hostedConnectionIds().union(hostedHere)
        let shown = host?.selectedConnectionId
        var statuses: [UUID: ConnectionDisplayStatus] = [:]
        var placements: [UUID: ConnectionNavigatorPlacement] = [:]
        for connection in connections {
            statuses[connection.id] = environment.status(connection.id)
            placements[connection.id] = ConnectionNavigatorRowsBuilder.placement(
                of: connection.id,
                shown: shown,
                hostedHere: hostedHere,
                hostedAnywhere: hostedAnywhere
            )
        }
        return (statuses, placements)
    }

    /// Whether a group is open now. A row's own flag is what it was when the rows were built, and
    /// the user opens and closes groups without a rebuild. A filter's choice lasts until it changes.
    internal func isGroupExpanded(_ group: ConnectionNavigatorGroupRow) -> Bool {
        isFiltering ? group.isExpanded : expandedGroupIds.contains(group.id)
    }

    /// The groups a filter opens are the filter's, so a user expanding or collapsing one while it
    /// runs does not overwrite what they chose before typing.
    internal func setGroupExpanded(_ id: UUID, _ expanded: Bool) {
        guard !isFiltering else { return }
        if expanded {
            expandedGroupIds.insert(id)
        } else {
            expandedGroupIds.remove(id)
        }
        updateStoredExpansion { stored in
            if expanded {
                stored.insert(id)
            } else {
                stored.remove(id)
            }
        }
    }

    /// Every window's navigator saves to the same key, so a change goes onto what is stored now.
    /// Saving this window's own copy wiped the groups another window had opened since it loaded.
    private func updateStoredExpansion(_ change: (inout Set<UUID>) -> Void) {
        let store = environment.expansionStore
        var stored = store.load(keeping: Set(environment.groupStorage.loadGroups().map(\.id)))
        change(&stored)
        store.save(stored)
    }

    // MARK: - Interaction

    /// A click switches only between connections this window already hosts. Anything else is a
    /// highlight: a list holding production servers must not dial one because the pointer slipped.
    internal func handleClick(on row: ConnectionNavigatorRowID?) {
        guard case .connection(let id) = row,
              let host,
              host.hostedConnectionIds.contains(id),
              host.selectedConnectionId != id
        else { return }
        host.selectHostedConnection(id)
    }

    /// Double click and Return. The router raises a window that already hosts the connection, and
    /// otherwise opens it in the frontmost one, which is this one.
    internal func open(_ connectionId: UUID) async {
        do {
            try await environment.router.route(.openConnection(connectionId))
        } catch {
            report(error, connectionId: connectionId)
        }
    }

    /// A connect that reached a window fails inline in its pane. Only an error raised before any
    /// window took the connection, such as a record deleted meanwhile, is this list's to show.
    private func report(_ error: Error, connectionId: UUID) {
        let isShownInWindow = environment.hostedConnectionIds().contains(connectionId)
            || host?.hostedConnectionIds.contains(connectionId) == true
        switch WelcomeViewModel.route(for: error, isShownInWindow: isShownInWindow) {
        case .ignore, .window:
            Self.logger.info("Open handled in its window: \(error.publicLogShape, privacy: .public)")
        case .pluginInstall, .alert:
            Self.logger.error("Failed to open the connection: \(error.publicLogShape, privacy: .public)")
            onOpenFailure?(error)
        }
    }

    internal func menuTarget(for row: ConnectionNavigatorRowID?) -> ConnectionNavigatorMenuTarget {
        switch row {
        case .group(let id):
            return .group(id)
        case .connection(let id):
            let hostedHere = Set(host?.hostedConnectionIds ?? [])
            return .connection(ConnectionNavigatorMenuConnection(
                id: id,
                placement: ConnectionNavigatorRowsBuilder.placement(
                    of: id,
                    shown: host?.selectedConnectionId,
                    hostedHere: hostedHere,
                    hostedAnywhere: environment.hostedConnectionIds().union(hostedHere)
                ),
                status: environment.status(id),
                holdsSession: environment.holdsSession(id),
                canMoveToNewWindow: environment.canMoveToNewWindow(id)
            ))
        case nil:
            return .empty
        }
    }

    /// Every command but New Group, whose sheet belongs to the view that presents it.
    internal func perform(_ command: ConnectionNavigatorCommand, presentingWindow: NSWindow?) {
        switch command {
        case .switchTo(let id):
            host?.selectHostedConnection(id)
        case .open(let id):
            Task { await open(id) }
        case .openInNewWindow(let id):
            openInNewWindow(id)
        case .disconnect(let id):
            let name = connections.first { $0.id == id }?.name ?? ""
            Task {
                await ConnectionDisconnectAction.disconnect(
                    connectionId: id,
                    connectionName: name,
                    presentingWindow: presentingWindow
                )
            }
        case .edit(let id):
            WindowOpener.shared.openConnectionForm(editing: id)
        case .duplicate(let id):
            duplicate(id)
        case .newConnection:
            WindowOpener.shared.openConnectionForm()
        case .newGroup:
            return
        }
    }

    /// A connection this window hosts moves out with its tabs and session, as the strip's command
    /// does; one nobody hosts opens in a window of its own.
    private func openInNewWindow(_ id: UUID) {
        if host?.hostedConnectionIds.contains(id) == true {
            WindowManager.shared.moveToNewWindow(connectionId: id)
            return
        }
        Task {
            do {
                try await environment.router.openConnectionPreferringNewWindow(id: id)
            } catch {
                report(error, connectionId: id)
            }
        }
    }

    private func duplicate(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }),
              let copy = environment.connectionStorage.duplicateConnection(connection)
        else {
            Self.logger.error("Duplicate found no connection to copy or could not save the copy")
            return
        }
        WindowOpener.shared.openConnectionForm(editing: copy.id)
    }

    /// Made through the store the Welcome window uses, so the same name, cycle and depth checks
    /// apply. The group and its parent open, since a new group nobody can see looks like a failure.
    internal func createGroup(_ fields: ConnectionGroupFields) throws {
        let group = ConnectionGroup(
            name: fields.name,
            color: fields.color,
            iconName: fields.iconName,
            parentId: fields.parentId
        )
        try environment.groupStorage.addGroup(group)
        let opened = Set([group.id] + [fields.parentId].compactMap { $0 })
        expandedGroupIds.formUnion(opened)
        updateStoredExpansion { $0.formUnion(opened) }
        rebuild()
    }
}
