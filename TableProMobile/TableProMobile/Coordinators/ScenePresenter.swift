import Foundation
import Observation
import TableProModels

enum SceneSheet: Identifiable {
    case firstRun([FirstRunPage])
    case whatsNew(version: String)
    case addConnection
    case editConnection(DatabaseConnection)
    case moveConnections([UUID])
    case newGroup(parentId: UUID?)
    case editGroup(ConnectionGroup)
    case tags
    case settings
    case importFile(URL)
    case export

    var id: String {
        switch self {
        case .firstRun: "firstRun"
        case .whatsNew(let version): "whatsNew-\(version)"
        case .addConnection: "addConnection"
        case .editConnection(let connection): "editConnection-\(connection.id.uuidString)"
        case .moveConnections(let ids): "moveConnections-\(ids.map(\.uuidString).joined(separator: ","))"
        case .newGroup(let parentId): "newGroup-\(parentId?.uuidString ?? "root")"
        case .editGroup(let group): "editGroup-\(group.id.uuidString)"
        case .tags: "tags"
        case .settings: "settings"
        case .importFile(let url): "importFile-\(url.absoluteString)"
        case .export: "export"
        }
    }

    var isLaunchPresentation: Bool {
        switch self {
        case .firstRun, .whatsNew: true
        default: false
        }
    }
}

nonisolated struct PendingTableRequest: Hashable, Sendable {
    let connectionId: UUID
    let tableName: String
}

@MainActor @Observable
final class ScenePresenter {
    /// Why the stored connection is not being restored yet. Each reason is inserted and removed by
    /// its own owner, so releasing one while the other stands keeps the restore waiting.
    enum RestoreHold: Hashable, Sendable {
        case firstRun
        case appLock
    }

    let sceneId = UUID()

    var sheet: SceneSheet?
    private(set) var editingConnectionId: UUID?
    private(set) var pendingIntent: SceneIntent?
    private(set) var pendingTable: PendingTableRequest?
    private(set) var restoreHolds: Set<RestoreHold> = []
    private(set) var editorHolds: Set<UUID> = []
    private(set) var isLocked: Bool

    var holdsConnectionRestore: Bool { !restoreHolds.isEmpty }

    var isHeldByEditor: Bool { !editorHolds.isEmpty }

    @ObservationIgnored private var hasBegunLaunch = false
    @ObservationIgnored private var presentedLaunchSheet = false
    @ObservationIgnored private var presentedFirstRunPages: [FirstRunPage] = []

    init(isLocked: Bool) {
        self.isLocked = isLocked
        if isLocked {
            restoreHolds.insert(.appLock)
        }
    }

    /// The lock hold is seeded at construction and released on the first unlock, never taken again.
    /// Re-taking it over a presented connection makes SwiftUI call the restore binding's setter with
    /// nil, which erases the stored connection id rather than postponing it.
    func lockDidChange(_ isLocked: Bool) {
        self.isLocked = isLocked
        guard !isLocked else { return }
        restoreHolds.remove(.appLock)
    }

    func beginLaunch(with appState: AppState) {
        guard !hasBegunLaunch else { return }
        hasBegunLaunch = true
        switch appState.claimLaunchPresentation(for: sceneId) {
        case .none:
            return
        case .firstRun(let pages):
            restoreHolds.insert(.firstRun)
            presentedFirstRunPages = pages
            present(.firstRun(pages))
        case .whatsNew(let version):
            present(.whatsNew(version: version))
        }
    }

    func sheetDidDismiss(appState: AppState) {
        guard presentedLaunchSheet, sheet == nil else { return }
        presentedLaunchSheet = false
        restoreHolds.remove(.firstRun)
        appState.finishFirstRun(pages: presentedFirstRunPages)
        presentedFirstRunPages = []
        appState.releaseLaunchPresentation(for: sceneId)
    }

    func releaseLaunchClaim(appState: AppState) {
        appState.releaseLaunchPresentation(for: sceneId)
    }

    func present(_ newSheet: SceneSheet) {
        if newSheet.isLaunchPresentation {
            presentedLaunchSheet = true
        }
        sheet = newSheet
    }

    func presentConnectionEditor(for connectionId: UUID) {
        editingConnectionId = connectionId
    }

    func dismissConnectionEditor() {
        editingConnectionId = nil
    }

    func isEditingConnection(_ connectionId: UUID) -> Bool {
        editingConnectionId == connectionId
    }

    func receive(_ intent: SceneIntent) {
        pendingIntent = intent
    }

    func setEditorHold(_ token: UUID, isHolding: Bool) {
        guard editorHolds.contains(token) != isHolding else { return }
        if isHolding {
            editorHolds.insert(token)
        } else {
            editorHolds.remove(token)
        }
    }

    func takeDeliverableIntent(isLibraryWritable: Bool) -> SceneIntent? {
        guard let pendingIntent, sheet == nil, !isLocked, !holdsConnectionRestore, !isHeldByEditor else { return nil }
        if case .importConnections = pendingIntent, !isLibraryWritable {
            return nil
        }
        self.pendingIntent = nil
        return pendingIntent
    }

    func requestTable(_ tableName: String?, in connectionId: UUID) {
        pendingTable = tableName.map { PendingTableRequest(connectionId: connectionId, tableName: $0) }
    }

    func takeTable(for connectionId: UUID) -> String? {
        guard let pendingTable, pendingTable.connectionId == connectionId else { return nil }
        self.pendingTable = nil
        return pendingTable.tableName
    }
}
