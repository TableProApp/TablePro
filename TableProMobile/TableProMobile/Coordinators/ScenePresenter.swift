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
    /// its own owner, so releasing one while the others stand keeps the restore waiting.
    enum RestoreHold: Hashable, Sendable {
        case firstRun
        case appLock
        case pendingIntent
    }

    let sceneId = UUID()

    var sheet: SceneSheet?
    private(set) var editingConnectionId: UUID?
    private(set) var pendingIntent: SceneIntent?
    private(set) var pendingTable: PendingTableRequest?
    private(set) var restoreHolds: Set<RestoreHold> = []
    private(set) var editorHolds: Set<UUID> = []
    private(set) var heldImportFile: URL?

    var holdsConnectionRestore: Bool { !restoreHolds.isEmpty }

    var isHeldByEditor: Bool { !editorHolds.isEmpty }

    @ObservationIgnored private var hasBegunLaunch = false
    @ObservationIgnored private var presentedLaunchSheet = false
    @ObservationIgnored private var presentedFirstRunPages: [FirstRunPage] = []

    init(isLockedAtLaunch: Bool = false) {
        guard isLockedAtLaunch else { return }
        restoreHolds.insert(.appLock)
    }

    /// The lock hold is taken at launch and released on the first unlock, never taken again: a lock
    /// the user came back from is not a reason to postpone a restore that already happened, and the
    /// lock screen is a window of its own over whatever is open. Releasing it is not the same as
    /// answering "is the app locked": that stays a live read the caller passes in, because a copy
    /// kept here is only as fresh as the last view update that remembered to refresh it.
    func lockDidChange(_ isLocked: Bool) {
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

    /// A sheet cannot take the screen from a cover that is still on it, so a file that arrives over
    /// an open connection waits for the dismissal the cleared selection is about to produce. What
    /// the caller passes is what SwiftUI has on screen, never what it has been asked to show:
    /// measured on iOS 27, a cover the body has only read is cancelled without a trace when the same
    /// update clears it, and nothing would ever call `presentHeldImport`.
    func presentImportFile(_ url: URL, coverIsOnScreen: Bool) {
        guard coverIsOnScreen else {
            present(.importFile(url))
            return
        }
        heldImportFile = url
    }

    func presentHeldImport() {
        guard let url = heldImportFile else { return }
        heldImportFile = nil
        present(.importFile(url))
    }

    /// A restore hold postpones a connection that is not open yet; it never closes one that is.
    func presentsConnectionCover(isOnScreen: Bool) -> Bool {
        isOnScreen || !holdsConnectionRestore
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

    /// A link waiting to be delivered holds the restore, so the stored connection is never opened in
    /// the same turn the link is handled. The link either replaces it (`openConnection`) or wants the
    /// list in front of it (`importConnections`), and a restore that commits first leaves the delivery
    /// to guess whether a cover it can no longer see is about to appear.
    func receive(_ intent: SceneIntent) {
        pendingIntent = intent
        restoreHolds.insert(.pendingIntent)
    }

    func setEditorHold(_ token: UUID, isHolding: Bool) {
        guard editorHolds.contains(token) != isHolding else { return }
        if isHolding {
            editorHolds.insert(token)
        } else {
            editorHolds.remove(token)
        }
    }

    /// The intent's own hold never blocks it: it is there to keep the restore from running ahead of
    /// the delivery, and it is released by the delivery itself.
    func takeDeliverableIntent(isLocked: Bool, isLibraryWritable: Bool) -> SceneIntent? {
        let blockingHolds = restoreHolds.subtracting([.pendingIntent])
        guard let pendingIntent, sheet == nil, !isLocked, blockingHolds.isEmpty, !isHeldByEditor else { return nil }
        if case .importConnections = pendingIntent, !isLibraryWritable {
            return nil
        }
        self.pendingIntent = nil
        restoreHolds.remove(.pendingIntent)
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
