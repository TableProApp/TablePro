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
    let sceneId = UUID()

    var sheet: SceneSheet?
    private(set) var pendingIntent: SceneIntent?
    private(set) var pendingTable: PendingTableRequest?
    private(set) var holdsConnectionRestore = false

    @ObservationIgnored private var hasBegunLaunch = false
    @ObservationIgnored private var presentedLaunchSheet = false
    @ObservationIgnored private var presentedFirstRunPages: [FirstRunPage] = []

    func beginLaunch(with appState: AppState) {
        guard !hasBegunLaunch else { return }
        hasBegunLaunch = true
        switch appState.claimLaunchPresentation(for: sceneId) {
        case .none:
            return
        case .firstRun(let pages):
            holdsConnectionRestore = true
            presentedFirstRunPages = pages
            present(.firstRun(pages))
        case .whatsNew(let version):
            present(.whatsNew(version: version))
        }
    }

    func sheetDidDismiss(appState: AppState) {
        guard presentedLaunchSheet, sheet == nil else { return }
        presentedLaunchSheet = false
        holdsConnectionRestore = false
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

    func receive(_ intent: SceneIntent) {
        pendingIntent = intent
    }

    func takeDeliverableIntent(isLocked: Bool, isLibraryWritable: Bool) -> SceneIntent? {
        guard let pendingIntent, sheet == nil, !isLocked, !holdsConnectionRestore else { return nil }
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
