import Foundation
import Observation
import os
import TableProConnectionLibrary
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProSQLGrammar

// What a window shows of its connection: the model's, or what it showed when the session moved under an unsaved edit.
struct ConnectionSnapshot {
    let state: ConnectionSessionState
    let catalog: ConnectionCatalog
}

struct ConnectionFailure {
    let error: any Error
    let title: String
    // A failed read that a redial repeats needs no alert once the redial lands.
    let redialRepeats: Bool
}

// One per connection, kept while a window holds it.
final class ConnectionSessionModels {
    private struct WeakModel {
        weak var model: ConnectionSessionModel?
    }

    private var models: [UUID: WeakModel] = [:]

    func model(for connection: DatabaseConnection, appState: AppState) -> ConnectionSessionModel {
        if let existing = models[connection.id]?.model {
            existing.adopt(connection)
            return existing
        }
        let created = ConnectionSessionModel(record: connection, appState: appState)
        models[connection.id] = WeakModel(model: created)
        return created
    }

    func existing(_ connectionId: UUID) -> ConnectionSessionModel? {
        models[connectionId]?.model
    }

    func purge(_ connectionIds: Set<UUID>) {
        for connectionId in connectionIds {
            models.removeValue(forKey: connectionId)
        }
    }
}

// The session every window of one connection shows: one lifecycle, one table list, one check, one catalog reload.
// A window asks through its `ConnectionCoordinator`, which keeps what is the window's own.
@MainActor @Observable
final class ConnectionSessionModel {
    private(set) var record: DatabaseConnection

    // Written only by `enter(_:)`, which refuses a step of an attempt the state no longer holds.
    private(set) var state: ConnectionSessionState = .notConnected {
        didSet { scenesSaw(ConnectionSnapshot(state: oldValue, catalog: catalog)) }
    }
    private(set) var catalog = ConnectionCatalog() {
        didSet { scenesSaw(ConnectionSnapshot(state: state, catalog: oldValue)) }
    }

    // A transaction lost with no window told yet; the next transition that lands a session reports it.
    @ObservationIgnored private var pendingLoss: SessionLoss?
    @ObservationIgnored private var seenCatalogGeneration: Int
    @ObservationIgnored private var isReloadingCatalog = false
    @ObservationIgnored private var catalogReloadRequested = false
    @ObservationIgnored private var isReloadingAfterRollBack = false
    @ObservationIgnored private var rollBackReloadRequested = false
    @ObservationIgnored private var catalogReloadHeldBack = false
    @ObservationIgnored private var isFollowing = false
    @ObservationIgnored private var followRequested = false
    @ObservationIgnored private weak var followRequester: ConnectionCoordinator?
    // Each request that moves the placement bumps it, so only the newest one lands.
    @ObservationIgnored private var placementEpoch = 0
    @ObservationIgnored private var switchesInFlight = 0
    @ObservationIgnored private var placementRestored = false
    @ObservationIgnored private var scenes: [WeakScene] = []

    private let appState: AppState
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionSessionModel")

    typealias SessionLoss = ConnectionCoordinator.SessionLoss
    private typealias Placement = ConnectionCatalog.Placement

    private struct WeakScene {
        weak var scene: ConnectionCoordinator?
    }

    init(record: DatabaseConnection, appState: AppState) {
        self.record = record
        self.appState = appState
        seenCatalogGeneration = appState.catalogChanges.generation(for: record.id)
    }

    var connectionId: UUID { record.id }

    var session: ConnectionSession? { state.session }

    var activeDatabase: String { catalog.placement.database }
    var activeSchema: String { catalog.placement.schema }

    private var isLost: Bool {
        if case .lost = state.phase { return true }
        return false
    }

    var displayName: String {
        record.name.isEmpty ? record.host : record.name
    }

    var supportsDatabaseSwitching: Bool {
        record.type == .mysql || record.type == .mariadb ||
        record.type == .tidb || record.type == .oceanbase ||
        record.type == .postgresql || record.type == .redshift ||
        record.type == .mssql || record.type == .clickhouse ||
        record.type == .mongodb || record.type == .cloudflareD1
    }

    var supportsSchemas: Bool {
        record.type == .postgresql || record.type == .redshift ||
        record.type == .mssql || record.type == .duckdb ||
        record.type == .oracle
    }

    private var redialsToSwitchDatabase: Bool {
        record.type == .postgresql || record.type == .redshift
    }

    func adopt(_ record: DatabaseConnection) {
        guard record.id == self.record.id, record != self.record else { return }
        self.record = record
    }

    // The first window restores where the connection was; a later one finds the model there already.
    func restorePersistedPlacement() {
        guard !placementRestored else { return }
        placementRestored = true
        let defaults = UserDefaults.standard
        catalog.placement = Placement(
            database: defaults.string(forKey: ConnectionDefaultsKey.lastDB.name(for: connectionId)) ?? "",
            schema: defaults.string(forKey: ConnectionDefaultsKey.lastSchema.name(for: connectionId)) ?? "public"
        )
    }

    func classify(_ error: any Error, operation: String) -> AppError {
        ErrorClassifier.classify(error, context: ErrorContext(
            operation: operation,
            databaseType: record.type,
            host: record.host,
            sshEnabled: record.sshEnabled,
            signsInWithIAM: record.iamSignIn != nil
        ))
    }

    // MARK: - Windows

    func register(_ scene: ConnectionCoordinator) {
        scenes.removeAll { $0.scene == nil }
        scenes.append(WeakScene(scene: scene))
    }

    private func scenesSaw(_ old: ConnectionSnapshot) {
        for scene in scenes.compactMap(\.scene) {
            scene.sessionModelChanged(from: old)
        }
    }

    private func consumers(of attempt: ConnectionAttempt) -> [ConnectionCoordinator] {
        let live = scenes.compactMap(\.scene)
        return attempt.consumers.compactMap { id in live.first { ObjectIdentifier($0) == id } }
    }

    // The window that asked, or the next one still waiting: it answers the attempt's questions and hears its outcome.
    private func lead(of attempt: ConnectionAttempt) -> ConnectionCoordinator? {
        consumers(of: attempt).first
    }

    // True when the session the model now holds sits somewhere else than `old` showed, so an unsaved edit made there
    // would land on another table.
    func moves(from old: ConnectionSnapshot) -> Bool {
        if catalog.placement != old.catalog.placement { return true }
        guard let live = state.session, live.driver !== old.state.session?.driver else { return false }
        let moved = movedPlacement(of: live, from: old.catalog.placement, includingDatabase: true)
        return moved.database != nil || moved.schema != nil
    }

    // MARK: - Lifecycle

    @discardableResult
    private func enter(_ event: ConnectionSessionState.Event) -> Bool {
        guard let next = state.applying(event) else { return false }
        state = next
        return true
    }

    private func isCurrent(_ attempt: ConnectionAttempt) -> Bool {
        state.attempt === attempt
    }

    func connect(from scene: ConnectionCoordinator) async {
        switch state {
        case .connecting(let open, _):
            await wait(on: open, from: scene)
        case .checking(let running, _), .reconnecting(let running, _):
            await wait(on: running, from: scene)
            if case .connected = state { await attach() }
        case .connected(let held):
            if appState.connectionManager.session(for: connectionId)?.driver === held.driver {
                await attach()
            } else {
                // The session ended under every window, as the background release does to a file.
                await restoreSession(after: .whileIdle, from: scene)
            }
        case .notConnected, .failed, .lost:
            await open(from: scene)
        }
    }

    // A window that joins answers the dial's questions too, and keeps the dial when the window that asked goes.
    private func wait(on attempt: ConnectionAttempt, from scene: ConnectionCoordinator) async {
        attempt.join(scene)
        await appState.sessionRedialer.settled(connectionId, consumer: scene, prompter: scene.prompts)
        _ = await attempt.task?.value
    }

    private func open(from scene: ConnectionCoordinator) async {
        let attempt = ConnectionAttempt(.open, origin: state.openOrigin)
        attempt.join(scene)
        let wanted = catalog.placement
        placementRestored = true
        enter(.open(attempt))
        attempt.task = Task { [weak self] in
            await self?.runAttempt(attempt, restoring: wanted)
            return false
        }
        _ = await attempt.task?.value
    }

    // A window that opens on a connected session reads the lists itself, which covers every change posted before.
    private func attach() async {
        guard let session else { return }
        let generation = appState.catalogChanges.generation(for: connectionId)
        var load = await loadTables(in: supportsSchemas ? activeSchema : nil, on: session)
        if supportsDatabaseSwitching { load.databases = try? await session.driver.fetchDatabases() }
        if supportsSchemas { load.schemas = try? await session.driver.fetchSchemas() }
        if load.failure == nil, commit(load, onFailure: .keep), generation > seenCatalogGeneration {
            seenCatalogGeneration = generation
        }
        await refreshTransaction()
        appState.libraryPreferences.recordConnected(connectionId)
    }

    // The last window to leave abandons what is in flight, so the next one never joins it and waits forever.
    func leave(_ scene: ConnectionCoordinator) {
        guard let attempt = state.attempt, attempt.leave(scene) else { return }
        enter(.abandon(attempt))
        if attempt.purpose == .open { attempt.task?.cancel() }
        leaveDial()
    }

    // The record changed how it dials, so the next window opens it again.
    func reset() {
        let attempt = state.attempt
        enter(.cancel)
        if attempt?.purpose == .open { attempt?.task?.cancel() }
        leaveDial()
    }

    private func leaveDial() {
        if appState.sessionRedialer.leave(connectionId, consumer: self) {
            appState.connectionManager.invalidateAttempt(for: connectionId)
        }
    }

    private func runAttempt(_ attempt: ConnectionAttempt, restoring wanted: Placement) async {
        // Another dial is shared once its schema is back, never torn down mid-dial.
        await appState.sessionRedialer.settled(connectionId, consumer: self, prompter: lead(of: attempt)?.prompts)
        guard isCurrent(attempt) else { return }
        if let existing = appState.connectionManager.session(for: connectionId) {
            let load = await loadTables(in: nil, on: existing)
            guard isCurrent(attempt) else { return }
            if load.failure == nil {
                let placement = adoptedPlacement(of: existing, includingDatabase: true)
                enter(.adopt(existing, by: attempt))
                commit(load, at: placement, onFailure: .keep)
                await finishOpen(attempt, restoring: wanted)
                return
            }
            if await keepsRefusingSession(existing, refused: load, by: attempt) { return }
            guard isCurrent(attempt) else { return }
            await appState.sessionRedialer.settled(connectionId, consumer: self, prompter: lead(of: attempt)?.prompts)
            guard isCurrent(attempt) else { return }
            if let live = appState.connectionManager.session(for: connectionId), live.driver !== existing.driver {
                await runAttempt(attempt, restoring: wanted)
                return
            }
            await appState.connectionManager.disconnect(connectionId)
        }

        guard isCurrent(attempt) else { return }
        await connectFresh(attempt, restoring: wanted)
    }

    // `allowSignIn` is false on the retry that follows a sign-in, so a connection that keeps
    // failing cannot put the prompt up again and again. That retry dials with the new credentials
    // rather than join a dial started without them.
    private func connectFresh(_ attempt: ConnectionAttempt, restoring wanted: Placement, allowSignIn: Bool = true) async {
        Telemetry.shared.connectionAttempted(databaseType: record.type.rawValue)

        do {
            let outcome = try await appState.sessionRedialer.redial(
                record,
                schema: nil,
                prompter: lead(of: attempt)?.prompts,
                joining: allowSignIn,
                consumer: self,
                stillWanted: { [weak self] in self?.isCurrent(attempt) == true }
            )
            let newSession = outcome.session
            let load = await loadTables(in: nil, on: newSession)
            if let refusal = load.failure { throw refusal }
            guard isCurrent(attempt) else { return }
            let placement = adoptedPlacement(of: newSession, includingDatabase: true)
            enter(.adopt(newSession, by: attempt))
            commit(load, at: placement, onFailure: .keep)
            if outcome.dialedHere {
                appState.bumpSessionRevision(connectionId)
            }
            guard await finishOpen(attempt, restoring: wanted) else { return }
            Telemetry.shared.connectionSucceeded(databaseType: record.type.rawValue)
            for scene in consumers(of: attempt) {
                scene.navigateToPendingTable()
            }
        } catch {
            guard isCurrent(attempt) else { return }
            var failure = error
            // A sign-in that expired is recoverable, so offer it once and retry rather than
            // leaving the user on an error screen whose only button repeats the same failure.
            if allowSignIn, let prompts = lead(of: attempt)?.prompts,
               let method = SignInOffer.method(for: error, connection: record, secureStore: appState.secureStore) {
                switch await SignInOffer.offer(method, prompts: prompts) {
                case .signedIn:
                    guard isCurrent(attempt) else { return }
                    await connectFresh(attempt, restoring: wanted, allowSignIn: false)
                    return
                case .failed(let signInError):
                    failure = signInError
                case .declined:
                    break
                }
            }
            guard isCurrent(attempt) else { return }
            enter(.fail(classify(failure, operation: "connect"), attempt))
        }
    }

    // The open landed where the session is; this puts it back where the connection was, through the asking window.
    @discardableResult
    private func finishOpen(_ attempt: ConnectionAttempt, restoring wanted: Placement) async -> Bool {
        await loadDatabases(restoring: wanted.database, from: lead(of: attempt))
        await loadSchemas(restoring: wanted.schema, from: lead(of: attempt))
        await refreshTransaction()
        // A database restore that failed both ways left the open lost, and it stays lost.
        guard enter(.opened(attempt)) else { return false }
        appState.libraryPreferences.recordConnected(connectionId)
        reportDroppedTransaction(pendingLoss, to: lead(of: attempt))
        return true
    }

    // A transaction the server aborted refuses catalog reads, yet the session still holds the user's work.
    private func keepsRefusingSession(
        _ existing: ConnectionSession,
        refused load: CatalogLoad,
        by attempt: ConnectionAttempt
    ) async -> Bool {
        guard let refusal = load.failure, await Self.answersPing(existing.driver), isCurrent(attempt) else { return false }
        await refreshTransaction()
        guard isCurrent(attempt),
              appState.sessionTransactions.hold(for: connectionId, on: existing.driver) != nil else { return false }
        Self.logger.info("Kept a session that refused its catalog: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        var placement = catalog.placement
        let database = sessionDatabase(of: existing)
        if supportsDatabaseSwitching, !database.isEmpty {
            placement.database = database
        }
        enter(.adopt(existing, by: attempt))
        commit(load, at: placement, onFailure: .refuse)
        enter(.opened(attempt))
        appState.libraryPreferences.recordConnected(connectionId)
        return true
    }

    // Another party ended the session the model holds, as the background release does to a file. The next
    // transition that lands a session reports what it held, whichever window asks.
    func sessionEnded(_ driver: any DatabaseDriver) {
        guard case .connected(let held) = state, held.driver === driver,
              let ended = appState.sessionTransactions.endedHold(for: connectionId, on: driver) else { return }
        if driver.holdsSuspensionBlockingResource {
            pendingLoss = ended.duringWork ? .inBackgroundAfterStatement : .inBackground
        } else {
            pendingLoss = ended.duringWork ? .duringWork : .whileIdle
        }
    }

    // MARK: - Session Check

    // True when the redial dropped a held transaction and the outcome is already settled for the user.
    @discardableResult
    func restoreSession(after loss: SessionLoss, from scene: ConnectionCoordinator) async -> Bool {
        // One check per connection, and a statement that failed while it ran makes the loss ambiguous.
        if let running = state.check, let task = running.task {
            if loss == .duringWork { running.ambiguous = true }
            running.join(scene)
            return await task.value
        }
        guard !scene.isSwitching else { return false }
        let check = ConnectionAttempt(.redial)
        check.join(scene)
        guard enter(.check(check)) else { return false }
        let task = Task { await checkSession(check, after: loss) }
        check.task = task
        return await task.value
    }

    private func checkSession(_ check: ConnectionAttempt, after loss: SessionLoss) async -> Bool {
        let held = session
        var workWasRunning = appState.sessionTransactions.isRunningStatements(connectionId)

        switch await newerSession(than: held, during: check) {
        case .taken:
            return reportDroppedTransaction(pendingLoss, to: lead(of: check))
        case .refused:
            enter(.settle(check))
            return false
        case .none:
            break
        }
        if let held {
            if appState.connectionManager.session(for: connectionId) != nil, await Self.answersPing(held.driver) {
                enter(.settle(check))
                return false
            }
            guard isCurrent(check) else { return false }
            // Another dial can land a whole session while this ping is out.
            switch await newerSession(than: held, during: check) {
            case .taken:
                return reportDroppedTransaction(pendingLoss, to: lead(of: check))
            case .refused:
                enter(.settle(check))
                return false
            case .none:
                break
            }
        }

        workWasRunning = workWasRunning || appState.sessionTransactions.isRunningStatements(connectionId)
        let ended = appState.sessionTransactions.endedHold(for: connectionId, on: held?.driver)
        workWasRunning = workWasRunning || ended?.duringWork == true
        let heldTransaction = appState.sessionTransactions.hold(for: connectionId, on: held?.driver) != nil
            || ended != nil
        let released = ended.flatMap { releasedLoss($0, on: held, asked: loss) }
        guard enter(.dial(check)) else { return false }
        do {
            let outcome = try await appState.sessionRedialer.redial(
                dialTarget,
                schema: supportsSchemas ? activeSchema : nil,
                prompter: lead(of: check)?.prompts,
                consumer: self,
                stillWanted: { [weak self] in self?.isCurrent(check) == true }
            )
            guard isCurrent(check),
                  await takeSession(outcome.session, dialedHere: outcome.dialedHere, by: check) else { return false }
            let dropped = heldTransaction
                ? released ?? Self.settledLoss(loss, workWasRunning: workWasRunning, ambiguous: check.ambiguous)
                : pendingLoss
            return reportDroppedTransaction(dropped, to: lead(of: check))
        } catch {
            guard isCurrent(check) else { return false }
            if heldTransaction {
                pendingLoss = released
                    ?? Self.settledLoss(loss, workWasRunning: workWasRunning, ambiguous: check.ambiguous)
            }
            enter(.lose(classify(error, operation: "reconnect"), check))
            return false
        }
    }

    private static func settledLoss(_ loss: SessionLoss, workWasRunning: Bool, ambiguous: Bool) -> SessionLoss {
        workWasRunning || ambiguous ? .duringWork : loss
    }

    // The release closed the file once its running statement ended, so a later failure on the closed file decides nothing.
    private func releasedLoss(
        _ ended: SessionTransactionMonitor.EndedHold,
        on held: ConnectionSession?,
        asked loss: SessionLoss
    ) -> SessionLoss? {
        guard held?.driver.holdsSuspensionBlockingResource == true else { return nil }
        if ended.duringWork { return .inBackgroundAfterStatement }
        return loss == .duringRollBack ? .duringRollBack : .inBackground
    }

    // True when the transaction a redial ended is settled for the user.
    @discardableResult
    private func reportDroppedTransaction(_ loss: SessionLoss?, to scene: ConnectionCoordinator?) -> Bool {
        pendingLoss = nil
        guard let loss else { return false }
        appState.sessionTransactions.noteRolledBack(connectionId)
        if let message = ConnectionCoordinator.lostTransactionMessage(loss, connectionName: displayName) {
            scene?.presentFailure(title: nil, message: message)
        }
        return true
    }

    private enum NewerSession {
        case none
        case taken
        case refused
    }

    private func newerSession(than held: ConnectionSession?, during check: ConnectionAttempt) async -> NewerSession {
        // A dial in flight is not ready to share until its schema is back.
        await appState.sessionRedialer.settled(connectionId, consumer: self, prompter: lead(of: check)?.prompts)
        guard isCurrent(check),
              let live = appState.connectionManager.session(for: connectionId),
              live.driver !== held?.driver else {
            return .none
        }
        return await takeSession(live, dialedHere: false, by: check) ? .taken : .refused
    }

    private var dialTarget: DatabaseConnection {
        guard supportsDatabaseSwitching, !activeDatabase.isEmpty else { return record }
        var target = record
        target.database = activeDatabase
        return target
    }

    // `lander` is the attempt that dialed or found the session; a follow takes it with none.
    @discardableResult
    private func takeSession(
        _ newSession: ConnectionSession,
        dialedHere: Bool,
        by lander: ConnectionAttempt?,
        yieldingToBusy: Bool = false
    ) async -> Bool {
        let placementAsked = movedPlacement(of: newSession, includingDatabase: !dialedHere)
        let load = await loadTables(in: nil, on: newSession)
        if let refusal = load.failure {
            Self.logger.warning("Failed to load tables on the new session: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        }
        if let lander, !isCurrent(lander) { return false }
        // Another switch that landed while the tables loaded made them the wrong database's.
        if yieldingToBusy,
           !canFollow || movedPlacement(of: newSession, includingDatabase: !dialedHere) != placementAsked {
            return false
        }
        // The dial restored the connection's schema; a failed restore leaves the default.
        let placement = adoptedPlacement(of: newSession, includingDatabase: !dialedHere)
        let moved = placement != catalog.placement
        guard enter(.adopt(newSession, by: lander)) else { return false }
        commit(load, at: placement, onFailure: moved ? .empty : .refuse)
        if dialedHere {
            appState.bumpSessionRevision(connectionId)
        }
        await refreshTransaction()
        return true
    }

    // A session dialed or moved elsewhere sits on that database and schema, so the lists follow it before any write
    // can name a table from the old list.
    private func adoptedPlacement(of taken: ConnectionSession, includingDatabase: Bool) -> Placement {
        let moved = movedPlacement(of: taken, includingDatabase: includingDatabase)
        return Placement(database: moved.database ?? activeDatabase, schema: moved.schema ?? activeSchema)
    }

    private func movedPlacement(
        of taken: ConnectionSession,
        from placement: Placement? = nil,
        includingDatabase: Bool
    ) -> (database: String?, schema: String?) {
        let base = placement ?? catalog.placement
        var database: String?
        if includingDatabase {
            let candidate = sessionDatabase(of: taken)
            if supportsDatabaseSwitching, !candidate.isEmpty, candidate != base.database { database = candidate }
        }
        var schema: String?
        if supportsSchemas, let current = taken.driver.currentSchema, current != base.schema { schema = current }
        return (database, schema)
    }

    private func sessionDatabase(of taken: ConnectionSession) -> String {
        guard let live = appState.connectionManager.session(for: connectionId), live.driver === taken.driver else {
            return taken.activeDatabase
        }
        return live.activeDatabase
    }

    private static func answersPing(_ driver: any DatabaseDriver) async -> Bool {
        do {
            _ = try await driver.ping()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Following

    private var canFollow: Bool {
        (session != nil || isLost) && switchesInFlight == 0 && !state.isReconnecting && !state.isOpening
    }

    // The manager holds a session this model did not land, or moved its own: the lists follow it there. A follow
    // asked while the model is busy runs once it is free, so a later move is never missed.
    func follow(from scene: ConnectionCoordinator) async {
        followRequester = scene
        guard canFollow, !isFollowing else {
            followRequested = true
            return
        }
        isFollowing = true
        defer { isFollowing = false }
        repeat {
            followRequested = false
            await followOnce(from: followRequester ?? scene)
        } while followRequested && canFollow
    }

    // What a busy model held back: a follow, and a catalog reload that would have read a placement in motion.
    func runHeldBackWork(from scene: ConnectionCoordinator) async {
        if followRequested, canFollow, !isFollowing {
            await follow(from: followRequester ?? scene)
        }
        if catalogReloadHeldBack, switchesInFlight == 0 {
            catalogReloadHeldBack = false
            await reloadChangedCatalog()
        }
    }

    private func followOnce(from scene: ConnectionCoordinator) async {
        if isLost {
            guard appState.connectionManager.session(for: connectionId) != nil else { return }
            await restoreSession(after: .whileIdle, from: scene)
            return
        }
        await appState.sessionRedialer.settled(connectionId, consumer: scene, prompter: scene.prompts)
        guard canFollow else {
            followRequested = true
            return
        }
        guard let held = session, let live = appState.connectionManager.session(for: connectionId) else { return }
        if live.driver !== held.driver {
            guard await takeSession(live, dialedHere: false, by: nil, yieldingToBusy: true) else {
                followRequested = true
                return
            }
            reportDroppedTransaction(pendingLoss, to: scene)
            await loadSchemas(restoring: activeSchema, from: scene)
            return
        }
        let moved = movedPlacement(of: live, includingDatabase: true)
        guard moved.database != nil || moved.schema != nil else { return }
        let request = beginPlacementRequest()
        let target = Placement(database: moved.database ?? activeDatabase, schema: moved.schema ?? activeSchema)
        let load = await loadTables(in: supportsSchemas ? target.schema : nil, on: live)
        if let refusal = load.failure {
            Self.logger.warning("Failed to load tables where the session moved: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        }
        // Another move that landed while the tables loaded made them the wrong placement's.
        guard canFollow, session?.driver === live.driver,
              movedPlacement(of: live, includingDatabase: true) == moved else {
            followRequested = true
            return
        }
        enter(.adopt(live, by: nil))
        commit(load, at: target, onFailure: .empty, for: request)
        // SQL Server lists another database's schemas.
        if moved.database != nil {
            await loadSchemas(restoring: activeSchema, from: scene)
        }
        await refreshTransaction()
    }

    // MARK: - Database / Schema Switching

    func beginSwitch() {
        switchesInFlight += 1
    }

    func endSwitch() {
        switchesInFlight -= 1
    }

    private func beginPlacementRequest() -> Int {
        placementEpoch += 1
        return placementEpoch
    }

    func switchDatabase(to name: String, from scene: ConnectionCoordinator) async -> ConnectionFailure? {
        let failure: ConnectionFailure?
        if redialsToSwitchDatabase {
            await reconnectWithDatabase(name, from: scene)
            failure = nil
        } else {
            failure = await useDatabase(name)
        }
        await refreshTransaction()
        appState.bumpSessionRevision(connectionId)
        return failure
    }

    // SQL Server lists another database's schemas; a redial already read them on its new session. It runs once the
    // switch ends, so restoring a schema there is not refused as a switch in flight.
    func loadSchemasAfterSwitch(to name: String, from scene: ConnectionCoordinator) async {
        guard !redialsToSwitchDatabase, activeDatabase == name else { return }
        await loadSchemas(restoring: activeSchema, from: scene)
    }

    private func useDatabase(_ name: String) async -> ConnectionFailure? {
        let request = beginPlacementRequest()
        do {
            try await appState.connectionManager.switchDatabase(connectionId, to: name)
        } catch {
            return ConnectionFailure(error: error, title: ConnectionCoordinator.switchDatabaseFailedTitle, redialRepeats: false)
        }
        if let freshSession = appState.connectionManager.session(for: connectionId) {
            enter(.adopt(freshSession, by: nil))
        }
        UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastDB.name(for: connectionId))
        guard let session else { return nil }
        let load = await loadTables(in: nil, on: session)
        // The session is on the new database either way, so a refused list empties until a reload can read it.
        commit(load, at: Placement(database: name, schema: activeSchema), onFailure: .empty, for: request)
        guard let refusal = load.failure else { return nil }
        return ConnectionFailure(error: refusal, title: ConnectionCoordinator.refreshTablesFailedTitle, redialRepeats: true)
    }

    // Inside an open the switch is the open's step; otherwise it is an attempt of its own, which no older step outlives.
    private func beginDatabaseSwitch(from scene: ConnectionCoordinator) -> ConnectionAttempt? {
        if case .connecting(let open, _) = state {
            return enter(.teardown(open)) ? open : nil
        }
        let attempt = ConnectionAttempt(.switchDatabase)
        attempt.join(scene)
        return enter(.switchDatabase(attempt)) ? attempt : nil
    }

    // Every window reads no session while a PostgreSQL switch runs; a switch asked then runs after it.
    var isSwitchingDatabase: Bool {
        guard case .reconnecting(let attempt, _) = state else { return false }
        return attempt.purpose == .switchDatabase
    }

    // A dial, a session check or another window's switch in flight lands first: the teardown would cancel the dial,
    // and the check's lost-transaction notice or the other switch would never land. The newest switch then wins.
    private func reconnectWithDatabase(_ database: String, from scene: ConnectionCoordinator) async {
        while true {
            await appState.sessionRedialer.settled(connectionId)
            guard let running = state.attempt, running.purpose != .open, let task = running.task else { break }
            _ = await task.value
            if state.attempt === running { break }
        }
        // A window closed during that wait must not tear down the session the other windows now use.
        guard scene.isAttached, activeDatabase != database,
              let switching = beginDatabaseSwitch(from: scene) else { return }
        guard switching.purpose == .switchDatabase else {
            await runDatabaseSwitch(to: database, as: switching, from: scene)
            return
        }
        let task = Task {
            await runDatabaseSwitch(to: database, as: switching, from: scene)
            return false
        }
        switching.task = task
        _ = await task.value
    }

    private func runDatabaseSwitch(
        to database: String,
        as switching: ConnectionAttempt,
        from scene: ConnectionCoordinator
    ) async {
        let request = beginPlacementRequest()
        let previous = dialTarget
        await appState.connectionManager.disconnect(connectionId)

        var newConnection = record
        newConnection.database = database

        do {
            let newSession = try await appState.sessionRedialer.redial(
                newConnection,
                schema: nil,
                prompter: scene.prompts,
                joining: false,
                consumer: self,
                stillWanted: { [weak self] in self?.isCurrent(switching) == true }
            ).session
            guard isCurrent(switching) else { return }
            let load = await loadTables(in: nil, on: newSession)
            if let refusal = load.failure { throw refusal }
            guard isCurrent(switching) else { return }
            enter(.adopt(newSession, by: switching))
            commit(load, at: Placement(database: database, schema: activeSchema), onFailure: .keep, for: request)
            UserDefaults.standard.set(database, forKey: ConnectionDefaultsKey.lastDB.name(for: connectionId))
            await loadSchemas(restoring: activeSchema, from: scene)
        } catch {
            guard isCurrent(switching) else { return }
            Self.logger.error("Failed to switch to database \(database, privacy: .private(mask: .hash)): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            // Back to the database the picker still shows, not the saved one, so the picker stays true.
            do {
                let fallback = try await appState.sessionRedialer.redial(
                    previous,
                    schema: supportsSchemas ? activeSchema : nil,
                    prompter: scene.prompts,
                    joining: false,
                    consumer: self,
                    stillWanted: { [weak self] in self?.isCurrent(switching) == true }
                )
                guard isCurrent(switching),
                      await takeSession(fallback.session, dialedHere: fallback.dialedHere, by: switching) else { return }
                scene.presentFailure(
                    title: ConnectionCoordinator.switchDatabaseFailedTitle,
                    message: classify(error, operation: "switchDatabase").message
                )
            } catch {
                guard isCurrent(switching) else { return }
                enter(.lose(classify(error, operation: "switchDatabase"), switching))
            }
        }
    }

    func switchSchema(to name: String, on session: ConnectionSession) async -> ConnectionFailure? {
        let request = beginPlacementRequest()
        do {
            try await session.driver.switchSchema(to: name)
        } catch {
            return ConnectionFailure(error: error, title: ConnectionCoordinator.switchSchemaFailedTitle, redialRepeats: false)
        }
        UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastSchema.name(for: connectionId))
        appState.bumpSessionRevision(connectionId)
        let load = await loadTables(in: name, on: session)
        // The session is on the new schema either way, so a refused list empties until a reload can read it.
        commit(load, at: Placement(database: activeDatabase, schema: name), onFailure: .empty, for: request)
        guard let refusal = load.failure else { return nil }
        return ConnectionFailure(error: refusal, title: ConnectionCoordinator.refreshTablesFailedTitle, redialRepeats: true)
    }

    // MARK: - Tables

    func refreshTables() async -> ConnectionFailure? {
        guard let session else { return nil }
        let load = await loadTables(in: supportsSchemas ? activeSchema : nil, on: session)
        commit(load, onFailure: .keep)
        guard let refusal = load.failure else { return nil }
        Self.logger.warning("Failed to refresh tables: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        return ConnectionFailure(error: refusal, title: ConnectionCoordinator.refreshTablesFailedTitle, redialRepeats: true)
    }

    func refreshTransaction() async {
        await appState.sessionTransactions.refresh(connectionId)
    }

    // A Roll Back from any window can undo DDL; every window asks, and one reload serves them all.
    func reloadAfterRollBack(from scene: ConnectionCoordinator) async {
        guard !isReloadingAfterRollBack else {
            rollBackReloadRequested = true
            return
        }
        isReloadingAfterRollBack = true
        defer { isReloadingAfterRollBack = false }
        repeat {
            rollBackReloadRequested = false
            await reloadAfterRollBackOnce(from: scene)
        } while rollBackReloadRequested
    }

    // A failed read keeps the list it has.
    private func reloadAfterRollBackOnce(from scene: ConnectionCoordinator) async {
        guard !catalog.tablesRefused else {
            await reloadMetadataIfReleased(from: scene)
            return
        }
        guard let session else { return }
        let load = await loadTables(in: supportsSchemas ? activeSchema : nil, on: session)
        commit(load, onFailure: .keep)
        if let refusal = load.failure {
            Self.logger.warning("Failed to reload tables after a Roll Back: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        }
        // With autocommit off, a MySQL read opens a transaction.
        await refreshTransaction()
    }

    func reloadMetadataIfReleased(from scene: ConnectionCoordinator) async {
        guard catalog.tablesRefused, let session,
              appState.sessionTransactions.hold(for: connectionId, on: session.driver) == nil else { return }
        let load = await loadTables(in: nil, on: session)
        if let refusal = load.failure {
            Self.logger.warning("Tables are still refused: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
            return
        }
        guard commit(load, onFailure: .keep, clearingRefusal: true) else { return }
        await loadDatabases(restoring: activeDatabase, from: scene)
        await loadSchemas(restoring: activeSchema, from: scene)
    }

    private enum OnFailure {
        case keep
        // The list stays, and reloads in full once nothing holds the session.
        case refuse
        case empty
    }

    private struct CatalogLoad {
        let driver: ObjectIdentifier
        let from: Placement
        let epoch: Int
        var tables: Result<[TableInfo], any Error>?
        var schemas: [String]?
        var databases: [String]?

        var failure: (any Error)? {
            guard case .failure(let error)? = tables else { return nil }
            return error
        }
    }

    private func loadTables(in schema: String?, on session: ConnectionSession) async -> CatalogLoad {
        let from = catalog.placement
        let epoch = placementEpoch
        let driver = ObjectIdentifier(session.driver)
        do {
            let tables = try await session.driver.fetchTables(schema: schema)
            return CatalogLoad(driver: driver, from: from, epoch: epoch, tables: .success(tables))
        } catch {
            return CatalogLoad(driver: driver, from: from, epoch: epoch, tables: .failure(error))
        }
    }

    // The one place a read lands. Placement and lists change in one step, and only on the session the read used: a
    // placement request only while it is the newest, any other read only while nothing moved since it started.
    @discardableResult
    private func commit(
        _ load: CatalogLoad,
        at placement: Placement? = nil,
        onFailure: OnFailure,
        clearingRefusal: Bool = false,
        for request: Int? = nil
    ) -> Bool {
        guard let session, ObjectIdentifier(session.driver) == load.driver else { return false }
        if let request {
            guard request == placementEpoch else { return false }
        } else {
            guard load.epoch == placementEpoch, catalog.placement == load.from else { return false }
        }
        var next = catalog
        next.placement = placement ?? catalog.placement
        switch load.tables {
        case .success(let tables)?:
            next.tables = tables
            if clearingRefusal { next.tablesRefused = false }
        case .failure?:
            switch onFailure {
            case .keep:
                break
            case .refuse:
                next.tablesRefused = true
            case .empty:
                next.tables = []
                next.tablesRefused = true
            }
        case nil:
            break
        }
        if let schemas = load.schemas { next.schemas = schemas }
        if let databases = load.databases { next.databases = databases }
        if next != catalog { catalog = next }
        return true
    }

    // MARK: - Catalog Changes

    // `reloadedHere`: the caller already read the session, the one place a transaction's own DDL shows.
    func noteCatalogChanged(_ kinds: SQLCatalogObjectKinds, reloadedHere: Bool) {
        let board = appState.catalogChanges
        let caughtUp = board.generation(for: connectionId) == seenCatalogGeneration
        board.post(kinds, for: connectionId)
        if reloadedHere, caughtUp {
            seenCatalogGeneration = board.generation(for: connectionId)
        }
    }

    // A statement a window ran may have created or dropped what the lists show; failed reads keep the lists.
    // One reload per connection: a later post waits for it, so an older answer never lands over a newer one.
    func reloadChangedCatalog() async {
        guard !isReloadingCatalog else {
            catalogReloadRequested = true
            return
        }
        isReloadingCatalog = true
        defer { isReloadingCatalog = false }
        repeat {
            catalogReloadRequested = false
            await reloadChangedCatalogOnce()
        } while catalogReloadRequested
    }

    private func reloadChangedCatalogOnce() async {
        let board = appState.catalogChanges
        let generation = board.generation(for: connectionId)
        guard generation != seenCatalogGeneration, let session else { return }
        // A placement in motion would make this read the wrong one's; the switch's end runs it again.
        guard switchesInFlight == 0 else {
            catalogReloadHeldBack = true
            return
        }
        var wanted = board.kinds(for: connectionId, since: seenCatalogGeneration)
        if !supportsSchemas { wanted.remove(.schemas) }
        if !supportsDatabaseSwitching { wanted.remove(.databases) }
        let kinds = wanted
        let database = supportsDatabaseSwitching ? activeDatabase : ""
        let schema = supportsSchemas ? activeSchema : nil
        let readFrom = catalog.placement
        let epoch = placementEpoch
        let monitor = appState.sessionTransactions
        let matchesSession = catalogMatchesSession(on: session.driver)

        var snapshot: CatalogSnapshot?
        // On the session a read would replace ROW_COUNT() and the warnings, so it is only where the DDL is visible, or
        // where a USE or a role moved the session off what the catalog connection sees, as Refresh reads it there too.
        if matchesSession {
            do {
                snapshot = try await appState.connectionManager.readCatalog(for: connectionId, database: database) {
                    try await Self.readCatalog(kinds, schema: schema, from: $0)
                }
            } catch {
                Self.logger.warning("Reloading the catalog after a change failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                seenCatalogGeneration = generation
                return
            }
        }
        if snapshot == nil {
            // A server that has a catalog connection but could not open one keeps its lists: a read on the session would
            // replace what the user's last statement left there. Only its own uncommitted DDL sends the read there.
            if matchesSession, appState.connectionManager.opensCatalogConnections(for: connectionId) {
                seenCatalogGeneration = generation
                return
            }
            // A stream on the session would end under this read, so it waits for the session to go idle.
            guard !monitor.isBusy(connectionId) else { return }
            board.beginSessionRead(for: connectionId)
            snapshot = try? await monitor.track(connectionId, reading: true) {
                try await Self.readCatalog(kinds, schema: schema, from: session.driver)
            }
            board.endSessionRead(for: connectionId)
        }
        seenCatalogGeneration = generation
        guard let snapshot else { return }
        var load = CatalogLoad(driver: ObjectIdentifier(session.driver), from: readFrom, epoch: epoch)
        if let tables = snapshot.tables { load.tables = .success(tables) }
        load.schemas = snapshot.schemas
        load.databases = snapshot.databases
        commit(load, onFailure: .keep)
    }

    private struct CatalogSnapshot: Sendable {
        var tables: [TableInfo]?
        var schemas: [String]?
        var databases: [String]?
    }

    // The table list is the read that matters: its failure fails the reload, so a dead connection is dropped.
    nonisolated private static func readCatalog(
        _ kinds: SQLCatalogObjectKinds,
        schema: String?,
        from driver: any DatabaseDriver
    ) async throws -> CatalogSnapshot {
        var snapshot = CatalogSnapshot()
        if kinds.contains(.tables) {
            snapshot.tables = try await driver.fetchTables(schema: schema)
        }
        if kinds.contains(.schemas) {
            snapshot.schemas = try? await driver.fetchSchemas()
        }
        if kinds.contains(.databases) {
            snapshot.databases = try? await driver.fetchDatabases()
        }
        return snapshot
    }

    private static let transactionalDDLTypes: Set<DatabaseType> = [.postgresql, .redshift, .mssql]

    // PostgreSQL, Redshift and SQL Server keep DDL inside the transaction that ran it, where only the session sees it;
    // a session that cannot say whether it holds one counts as holding one.
    func catalogSeesSessionDDL(on driver: (any DatabaseDriver)?) -> Bool {
        guard Self.transactionalDDLTypes.contains(record.type) else { return true }
        return appState.sessionTransactions.isKnownIdle(connectionId, on: driver)
    }

    // Completion reads beside the session only while both see the same tables: same DDL, same database, no table
    // only a procedure on the session made.
    func catalogMatchesSession(on driver: (any DatabaseDriver)?) -> Bool {
        guard catalogSeesSessionDDL(on: driver) else { return false }
        return !appState.catalogChanges.sessionLeftCatalog(
            for: connectionId, driver: driver.map { ObjectIdentifier($0) }
        )
    }

    // MARK: - Lists

    // `wanted` is where the connection was; the session may have opened elsewhere, and the asking window switches back.
    private func loadDatabases(restoring wanted: String, from scene: ConnectionCoordinator?) async {
        guard let session, supportsDatabaseSwitching else { return }
        do {
            let listed = try await session.driver.fetchDatabases()
            catalog.databases = listed
            let sessionDB = appState.connectionManager.session(for: connectionId)?.activeDatabase ?? record.database
            if !wanted.isEmpty, listed.contains(wanted) {
                catalog.placement.database = sessionDB
                if wanted != sessionDB {
                    await scene?.switchDatabase(to: wanted)
                }
            } else {
                catalog.placement.database = sessionDB
                // A database the connection names by its id is listed by its name, which the driver reports.
                if !listed.contains(activeDatabase), let reported = session.driver.currentDatabase,
                   listed.contains(reported) {
                    await scene?.switchDatabase(to: reported)
                }
            }
        } catch {
            Self.logger.warning("Failed to load databases: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadSchemas(restoring wanted: String, from scene: ConnectionCoordinator?) async {
        guard let session, supportsSchemas else { return }
        do {
            let listed = try await session.driver.fetchSchemas()
            catalog.schemas = listed
            let currentSchema = session.driver.currentSchema ?? "public"
            if listed.contains(wanted), wanted != currentSchema {
                catalog.placement.schema = currentSchema
                await scene?.switchSchema(to: wanted)
            } else if !listed.contains(activeSchema) {
                catalog.placement.schema = currentSchema
            }
        } catch {
            Self.logger.warning("Failed to load schemas: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}
