import Foundation
import Observation
import os
import SwiftUI
import TableProConnectionLibrary
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProSQLGrammar

@MainActor @Observable
final class ConnectionCoordinator {
    private(set) var connection: DatabaseConnection

    private(set) var session: ConnectionSession?
    private(set) var phase: ConnectionPhase = .connecting
    private(set) var tables: [TableInfo] = [] {
        didSet { selectedTable = TableSelectionResolver.keeping(selectedTable, in: tables) }
    }
    private(set) var databases: [String] = []
    private(set) var schemas: [String] = []
    private(set) var activeDatabase: String = ""
    private(set) var activeSchema: String = "public"

    private(set) var isSwitching = false {
        didSet { resumeFollowIfPending() }
    }
    private(set) var switchTarget: String?
    private(set) var isReconnecting = false {
        didSet { resumeFollowIfPending() }
    }
    // Another window moved the session while this one was busy; it follows once it is free.
    @ObservationIgnored private var followPending = false
    // A follow that changes the database rebuilds the table screen, which would drop an unsaved row edit.
    var isHeldByEditor = false {
        didSet {
            guard isHeldByEditor != oldValue else { return }
            appState.setEditorHold(isHeldByEditor, by: self, on: connection.id)
            resumeFollowIfPending()
        }
    }

    var anotherWindowHoldsEditor: Bool {
        appState.holdsEditor(connection.id, besides: self)
    }

    // One follow at a time, so an older one's late tables never land over a newer session's.
    @ObservationIgnored private var isFollowing = false {
        didSet { resumeFollowIfPending() }
    }
    @ObservationIgnored private(set) var resumedFollow: Task<Void, Never>?
    @ObservationIgnored private var sessionCheck: Task<Bool, Never>?
    @ObservationIgnored private var statementFailedDuringCheck = false
    @ObservationIgnored private var metadataRefused = false
    @ObservationIgnored private var seenCatalogGeneration: Int
    @ObservationIgnored private var isReloadingCatalog = false
    @ObservationIgnored private var catalogReloadRequested = false
    // A redial that failed over an open transaction; the user hears about it once a later dial lands.
    @ObservationIgnored private var unsettledLoss: SessionLoss?
    private(set) var failureAlertTitle: String?
    var failureAlertMessage: String?
    var showFailureAlert = false

    var selectedTab: ConnectedTab = .tables {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: ConnectionDefaultsKey.lastTab.name(for: connection.id))
        }
    }
    var pendingQuery: String?
    var pendingTableName: String?
    var selectedTable: TableInfo?

    private(set) var queryHistory: [QueryHistoryItem] = []
    private var historyStorage: QueryHistoryStorage { appState.queryHistory }

    private let appState: AppState

    var connectionManager: ConnectionManager { appState.connectionManager }
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionCoordinator")

    enum ConnectionPhase: Sendable {
        case notConnected
        case connecting
        case connected
        case failed(AppError)
        // The session dropped and its redial failed; the next trigger or Reconnect dials again.
        case lost(AppError)
    }

    var displayStatus: ConnectionDisplayStatus {
        ConnectionDisplayStatus(phase: phase, isReconnecting: isReconnecting)
    }

    private var isLost: Bool {
        if case .lost = phase { return true }
        return false
    }

    // A screen opened on an older session writes on this, so a save after a redial reaches the live driver and one
    // with no session says why rather than fail on a dead driver.
    var writableSession: Result<ConnectionSession, AppError> {
        if let session { return .success(session) }
        switch phase {
        case .lost(let error):
            let lost = ConnectionStatusPresentation(.lost(cause: error.message))
            return .failure(AppError(
                category: error.category,
                title: lost.title ?? error.title,
                message: error.message,
                recovery: error.recovery,
                underlying: error.underlying
            ))
        case .failed(let error):
            return .failure(error)
        case .notConnected, .connecting, .connected:
            return .failure(AppError(
                category: .network,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: nil,
                underlying: nil
            ))
        }
    }

    var displayName: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    var supportsDatabaseSwitching: Bool {
        connection.type == .mysql || connection.type == .mariadb ||
        connection.type == .tidb || connection.type == .oceanbase ||
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql || connection.type == .clickhouse ||
        connection.type == .mongodb || connection.type == .cloudflareD1
    }

    var supportsSchemas: Bool {
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql || connection.type == .duckdb ||
        connection.type == .oracle
    }

    init(connection: DatabaseConnection, appState: AppState) {
        self.connection = connection
        self.appState = appState
        seenCatalogGeneration = appState.catalogChanges.generation(for: connection.id)
    }

    // MARK: - Persisted State

    func restorePersistedState() {
        let defaults = UserDefaults.standard
        if let savedTab = defaults.string(forKey: ConnectionDefaultsKey.lastTab.name(for: connection.id)),
           let tab = ConnectedTab(rawValue: savedTab) {
            selectedTab = tab
        }
        activeDatabase = defaults.string(forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id)) ?? ""
        activeSchema = defaults.string(forKey: ConnectionDefaultsKey.lastSchema.name(for: connection.id)) ?? "public"
    }

    // MARK: - Connection Lifecycle

    // The attempt allowed to write `session` and `phase`. Cancelling mints a new one.
    private var attemptToken = UUID()
    private var connectTask: Task<Void, Never>? {
        didSet { resumeFollowIfPending() }
    }

    private var joiners = AttemptJoiners()

    let prompts = ConnectionPromptQueue()

    // Returning early without touching `phase` is what left the connecting screen up for good.
    func connect() async {
        prompts.expectScreen()
        if let inFlight = connectTask {
            await join(inFlight)
            return
        }

        let token = UUID()
        attemptToken = token
        phase = .connecting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAttempt(token: token)
        }
        connectTask = task
        await join(task)
        if connectTask == task { connectTask = nil }
    }

    // The last caller to go away abandons the attempt, so the next screen never joins it and waits forever.
    private func join(_ task: Task<Void, Never>) async {
        let joiner = joiners.join()
        await withTaskCancellationHandler {
            await task.value
            _ = joiners.leave(joiner)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard joiners.leave(joiner), connectTask == task else { return }
                cancelConnect()
            }
        }
    }

    func adopt(_ record: DatabaseConnection) {
        guard record.id == connection.id, record != connection else { return }
        connection = record
    }

    func retire() {
        attemptToken = UUID()
        connectTask?.cancel()
        connectTask = nil
        prompts.cancelAll()
        if appState.sessionRedialer.leave(connection.id, consumer: self) {
            appState.connectionManager.invalidateAttempt(for: connection.id)
        }
        appState.setEditorHold(false, by: self, on: connection.id)
        session = nil
    }

    // Never waits on the driver, which ignores `Task.cancel()`. The questions go first: a reconnect or a
    // database switch asks without owning `connectTask`, and a suspended one holds its tunnel open.
    // A lost session's redial is the session check, not `connectTask`; retiring mints a new attempt token, so a dial
    // that returns after Cancel is never adopted.
    func cancelConnect() {
        prompts.cancelAll()
        guard connectTask != nil || (isLost && isReconnecting) else { return }
        retire()
        phase = .notConnected
    }

    // A lost session redials where this window was, so the screen of a row edit in progress is not rebuilt.
    func reconnect() async {
        if isLost {
            await restoreSession(after: .whileIdle)
        } else {
            await connect()
        }
    }

    private func runAttempt(token: UUID) async {
        // Another window's dial is shared once its schema is back, never torn down mid-dial.
        await appState.sessionRedialer.settled(connection.id, consumer: self, prompter: prompts)
        guard attemptToken == token else { return }
        if let existing = appState.connectionManager.session(for: connection.id) {
            do {
                let existingTables = try await existing.driver.fetchTables(schema: nil)
                guard attemptToken == token else { return }
                session = existing
                tables = existingTables
                await loadDatabases()
                await loadSchemas()
                await refreshTransaction()
                guard attemptToken == token else { return }
                phase = .connected
                appState.libraryPreferences.recordConnected(connection.id)
                reportDroppedTransaction(unsettledLoss)
                return
            } catch {
                guard attemptToken == token else { return }
                if await keepsRefusingSession(existing, token: token, refusal: error) { return }
                guard attemptToken == token else { return }
                session = nil
                await appState.sessionRedialer.settled(connection.id, consumer: self, prompter: prompts)
                guard attemptToken == token else { return }
                if let live = appState.connectionManager.session(for: connection.id), live.driver !== existing.driver {
                    await runAttempt(token: token)
                    return
                }
                await appState.connectionManager.disconnect(connection.id)
            }
        }

        guard attemptToken == token else { return }
        await connectFresh(token: token)
    }

    // `allowSignIn` is false on the retry that follows a sign-in, so a connection that keeps
    // failing cannot put the prompt up again and again. That retry dials with the new credentials
    // rather than join a dial another window started without them.
    private func connectFresh(token: UUID, allowSignIn: Bool = true) async {
        Telemetry.shared.connectionAttempted(databaseType: connection.type.rawValue)

        do {
            let outcome = try await appState.sessionRedialer.redial(
                connection,
                schema: nil,
                prompter: prompts,
                joining: allowSignIn,
                consumer: self,
                stillWanted: { [weak self] in self?.attemptToken == token }
            )
            let newSession = outcome.session
            let newTables = try await newSession.driver.fetchTables(schema: nil)
            guard attemptToken == token else { return }
            if !outcome.dialedHere {
                adoptPlacement(of: newSession, includingDatabase: true)
            }
            session = newSession
            tables = newTables
            if outcome.dialedHere {
                appState.bumpSessionRevision(connection.id)
            }
            await loadDatabases()
            await loadSchemas()
            await refreshTransaction()
            guard attemptToken == token else { return }
            phase = .connected
            appState.libraryPreferences.recordConnected(connection.id)
            Telemetry.shared.connectionSucceeded(databaseType: connection.type.rawValue)
            navigateToPendingTable()
            reportDroppedTransaction(unsettledLoss)
        } catch {
            guard attemptToken == token else { return }
            var failure = error
            // A sign-in that expired is recoverable, so offer it once and retry rather than
            // leaving the user on an error screen whose only button repeats the same failure.
            if allowSignIn,
               let method = SignInOffer.method(for: error, connection: connection, secureStore: appState.secureStore) {
                switch await SignInOffer.offer(method, prompts: prompts) {
                case .signedIn:
                    guard attemptToken == token else { return }
                    await connectFresh(token: token, allowSignIn: false)
                    return
                case .failed(let signInError):
                    failure = signInError
                case .declined:
                    break
                }
            }
            guard attemptToken == token else { return }
            phase = .failed(classify(failure, operation: "connect"))
        }
    }

    private func classify(_ error: any Error, operation: String) -> AppError {
        ErrorClassifier.classify(error, context: ErrorContext(
            operation: operation,
            databaseType: connection.type,
            host: connection.host,
            sshEnabled: connection.sshEnabled,
            signsInWithIAM: connection.iamSignIn != nil
        ))
    }

    func reconnectIfNeeded() async {
        await restoreSession(after: .whileIdle)
    }

    enum SessionLoss {
        // Nothing was in flight, so the server rolled the transaction back.
        case whileIdle
        // A statement was in flight, and it may have committed the transaction before the reply was lost.
        case duringWork
        // The transaction is gone either way, which is what was asked for.
        case duringRollBack
    }

    // True when the redial dropped a held transaction and the outcome is already settled for the user.
    @discardableResult
    private func restoreSession(after loss: SessionLoss) async -> Bool {
        // One check at a time, and a statement that failed while it ran makes the loss ambiguous.
        if let sessionCheck {
            if loss == .duringWork { statementFailedDuringCheck = true }
            return await sessionCheck.value
        }
        statementFailedDuringCheck = false
        let check = Task {
            let settled = await checkSession(after: loss)
            sessionCheck = nil
            return settled
        }
        sessionCheck = check
        return await check.value
    }

    private func checkSession(after loss: SessionLoss) async -> Bool {
        let held = session
        // A failed redial dropped the session, so there is nothing to ping and this trigger dials again.
        guard held != nil || isLost, !isSwitching, !isReconnecting, connectTask == nil else { return false }
        let token = attemptToken
        var workWasRunning = appState.sessionTransactions.isRunningStatements(connection.id)

        switch await newerSession(than: held, token: token) {
        case .taken:
            return held == nil && reportDroppedTransaction(unsettledLoss)
        case .deferred:
            return false
        case .none:
            break
        }
        if let held {
            if appState.connectionManager.session(for: connection.id) != nil, await Self.answersPing(held.driver) {
                return false
            }
            guard attemptToken == token else { return false }
            // Another window can finish a whole redial while this ping is out.
            if await newerSession(than: held, token: token) != .none { return false }
        }

        workWasRunning = workWasRunning || appState.sessionTransactions.isRunningStatements(connection.id)
        let heldTransaction = transactionHold != nil
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            let outcome = try await appState.sessionRedialer.redial(
                dialTarget,
                schema: supportsSchemas ? activeSchema : nil,
                prompter: prompts,
                consumer: self,
                stillWanted: { [weak self] in self?.attemptToken == token }
            )
            guard attemptToken == token else { return false }
            await takeSession(outcome.session, token: token, dialedHere: outcome.dialedHere)
            guard attemptToken == token else { return false }
            let dropped = heldTransaction ? settledLoss(loss, workWasRunning: workWasRunning) : unsettledLoss
            return reportDroppedTransaction(dropped)
        } catch {
            guard attemptToken == token else { return false }
            if heldTransaction {
                unsettledLoss = settledLoss(loss, workWasRunning: workWasRunning)
            }
            phase = .lost(classify(error, operation: "reconnect"))
            self.session = nil
            return false
        }
    }

    private func settledLoss(_ loss: SessionLoss, workWasRunning: Bool) -> SessionLoss {
        workWasRunning || statementFailedDuringCheck ? .duringWork : loss
    }

    // True when the transaction a redial ended is settled for the user.
    @discardableResult
    private func reportDroppedTransaction(_ loss: SessionLoss?) -> Bool {
        unsettledLoss = nil
        guard let loss else { return false }
        appState.sessionTransactions.noteRolledBack(connection.id)
        if let message = Self.lostTransactionMessage(loss, connectionName: displayName) {
            presentFailure(title: nil, message: message)
        }
        return true
    }

    private enum NewerSession {
        case none
        case taken
        // Another window holds it on another database or schema, and this window's unsaved edit belongs where it is.
        case deferred
    }

    private func newerSession(than held: ConnectionSession?, token: UUID) async -> NewerSession {
        // A redial another window started is not ready to share until its schema is back.
        await appState.sessionRedialer.settled(connection.id, consumer: self, prompter: prompts)
        guard attemptToken == token,
              let live = appState.connectionManager.session(for: connection.id),
              live.driver !== held?.driver else {
            return .none
        }
        guard !editPins(against: live) else {
            followPending = true
            return .deferred
        }
        return await takeSession(live, token: token, dialedHere: false) ? .taken : .deferred
    }

    // An unsaved edit belongs to the placement it was made in, so a session elsewhere waits until the edit ends;
    // taking it would rebuild the editor's screen, or point its save at a same-named table in another database.
    private func editPins(against live: ConnectionSession) -> Bool {
        guard isHeldByEditor else { return false }
        let moved = movedPlacement(of: live, includingDatabase: true)
        return moved.database != nil || moved.schema != nil
    }

    private var dialTarget: DatabaseConnection {
        guard supportsDatabaseSwitching, !activeDatabase.isEmpty else { return connection }
        var target = connection
        target.database = activeDatabase
        return target
    }

    @discardableResult
    private func takeSession(
        _ newSession: ConnectionSession,
        token: UUID,
        dialedHere: Bool,
        yieldingToEdits: Bool = false
    ) async -> Bool {
        let placementAsked = movedPlacement(of: newSession, includingDatabase: !dialedHere)
        let fetched: [TableInfo]?
        do {
            fetched = try await newSession.driver.fetchTables(schema: nil)
        } catch {
            Self.logger.warning("Failed to load tables on the new session: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            fetched = nil
        }
        guard attemptToken == token else { return false }
        if !dialedHere, editPins(against: newSession) {
            followPending = true
            return false
        }
        // A row edit started while the tables loaded lives on a screen this would rebuild, and another switch that
        // landed meanwhile made these tables the wrong database's.
        if yieldingToEdits,
           !canFollowLiveSession || movedPlacement(of: newSession, includingDatabase: !dialedHere) != placementAsked {
            followPending = true
            return false
        }
        // The dial restored this window's schema, or another window's; a failed restore leaves the default.
        let movedPlacement = adoptPlacement(of: newSession, includingDatabase: !dialedHere)
        if let fetched {
            tables = fetched
        } else {
            metadataRefused = true
            if movedPlacement { tables = [] }
        }
        session = newSession
        phase = .connected
        if dialedHere {
            appState.bumpSessionRevision(connection.id)
        }
        await refreshTransaction()
        return true
    }

    // A session another window dialed or moved sits on that window's database and schema, so this one
    // follows it before any write can name a table from the old list.
    @discardableResult
    private func adoptPlacement(of taken: ConnectionSession, includingDatabase: Bool) -> Bool {
        let moved = movedPlacement(of: taken, includingDatabase: includingDatabase)
        if let database = moved.database { activeDatabase = database }
        if let schema = moved.schema { activeSchema = schema }
        return moved.database != nil || moved.schema != nil
    }

    private func movedPlacement(of taken: ConnectionSession, includingDatabase: Bool) -> (database: String?, schema: String?) {
        var database: String?
        if includingDatabase {
            let candidate = sessionDatabase(of: taken)
            if supportsDatabaseSwitching, !candidate.isEmpty, candidate != activeDatabase { database = candidate }
        }
        var schema: String?
        if supportsSchemas, let current = taken.driver.currentSchema, current != activeSchema { schema = current }
        return (database, schema)
    }

    // Another window replaced the shared session, or switched its database or schema.
    func followLiveSession() async {
        guard canFollowLiveSession, !isFollowing else {
            followPending = true
            return
        }
        // A window whose redial failed takes the session another window dialed.
        if isLost {
            guard appState.connectionManager.session(for: connection.id) != nil else { return }
            await restoreSession(after: .whileIdle)
            return
        }
        isFollowing = true
        defer { isFollowing = false }
        let token = attemptToken
        await appState.sessionRedialer.settled(connection.id, consumer: self, prompter: prompts)
        guard attemptToken == token else { return }
        guard canFollowLiveSession else {
            followPending = true
            return
        }
        guard let held = session, let live = appState.connectionManager.session(for: connection.id) else { return }
        if live.driver !== held.driver {
            guard await takeSession(live, token: token, dialedHere: false, yieldingToEdits: true),
                  attemptToken == token else { return }
            await loadSchemas()
            return
        }
        let moved = movedPlacement(of: live, includingDatabase: true)
        guard moved.database != nil || moved.schema != nil else { return }
        let fetched: [TableInfo]?
        do {
            fetched = try await live.driver.fetchTables(schema: supportsSchemas ? moved.schema ?? activeSchema : nil)
        } catch {
            Self.logger.warning("Failed to load tables where another window moved the session: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            fetched = nil
        }
        guard attemptToken == token, session?.driver === live.driver else { return }
        // A row edit started while the tables loaded lives on a screen the new placement would rebuild, and another
        // switch that landed meanwhile made these tables the wrong database's.
        guard canFollowLiveSession, movedPlacement(of: live, includingDatabase: true) == moved else {
            followPending = true
            return
        }
        // Placement and tables change in one step, so a row of the old list never pairs with the new placement.
        if let database = moved.database { activeDatabase = database }
        if let schema = moved.schema { activeSchema = schema }
        session = live
        if let fetched {
            tables = fetched
        } else {
            metadataRefused = true
            tables = []
        }
        // SQL Server lists another database's schemas.
        if moved.database != nil {
            await loadSchemas()
            guard attemptToken == token else { return }
        }
        await refreshTransaction()
    }

    // Where an unqualified table name resolves for this window. Another window's switch can move it under an open
    // confirmation, so a destructive action checks it again before it runs.
    struct TablePlacement: Hashable {
        let driver: ObjectIdentifier?
        let database: String
        let schema: String?
    }

    var tablePlacement: TablePlacement {
        TablePlacement(
            driver: session.map { ObjectIdentifier($0.driver) },
            database: activeDatabase,
            schema: supportsSchemas ? activeSchema : nil
        )
    }

    static var editorHeldElsewhereMessage: String {
        String(localized: "Another window has unsaved changes on this connection. Save or discard them before switching database.")
    }

    private var canFollowLiveSession: Bool {
        (session != nil || isLost) && !isSwitching && !isReconnecting && connectTask == nil && !isHeldByEditor
    }

    private func resumeFollowIfPending() {
        guard followPending, canFollowLiveSession, !isFollowing else { return }
        followPending = false
        resumedFollow = Task { await followLiveSession() }
    }

    // A transaction the server aborted refuses catalog reads, yet the session still holds the user's work.
    private func keepsRefusingSession(_ existing: ConnectionSession, token: UUID, refusal: any Error) async -> Bool {
        guard await Self.answersPing(existing.driver), attemptToken == token else { return false }
        await refreshTransaction()
        guard attemptToken == token,
              appState.sessionTransactions.hold(for: connection.id, on: existing.driver) != nil else { return false }
        Self.logger.info("Kept a session that refused its catalog: \(LogRedaction.publicDescription(of: refusal), privacy: .public) \(refusal.localizedDescription, privacy: .private)")
        let database = sessionDatabase(of: existing)
        if supportsDatabaseSwitching, !database.isEmpty {
            activeDatabase = database
        }
        metadataRefused = true
        session = existing
        phase = .connected
        appState.libraryPreferences.recordConnected(connection.id)
        return true
    }

    private func sessionDatabase(of taken: ConnectionSession) -> String {
        guard let live = appState.connectionManager.session(for: connection.id), live.driver === taken.driver else {
            return taken.activeDatabase
        }
        return live.activeDatabase
    }

    static func lostTransactionMessage(_ loss: SessionLoss, connectionName: String) -> String? {
        switch loss {
        case .whileIdle:
            String(
                format: String(
                    localized: "The connection to %@ was lost while it waited, and the server rolled back its open transaction. It has been reconnected; run the statements again."
                ),
                connectionName
            )
        case .duringWork:
            String(
                format: String(
                    localized: "The connection to %@ was lost before the server answered, so its open transaction may have been committed or rolled back. It has been reconnected; check which of its changes were saved before running them again."
                ),
                connectionName
            )
        case .duringRollBack:
            nil
        }
    }

    private static func answersPing(_ driver: any DatabaseDriver) async -> Bool {
        do {
            _ = try await driver.ping()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Transactions

    var transactionHold: SessionTransactionMonitor.Hold? {
        appState.sessionTransactions.hold(for: connection.id, on: session?.driver)
    }

    // PostgreSQL, Redshift and SQL Server keep DDL inside the transaction that ran it, where only the session sees it;
    // a session that cannot say whether it holds one counts as holding one.
    var catalogSeesSessionDDL: Bool {
        guard Self.transactionalDDLTypes.contains(connection.type) else { return true }
        return appState.sessionTransactions.isKnownIdle(connection.id, on: session?.driver)
    }

    private static let transactionalDDLTypes: Set<DatabaseType> = [.postgresql, .redshift, .mssql]

    // Completion reads beside the session only while both see the same tables: same DDL, same database, no table
    // only a procedure on the session made.
    var catalogMatchesSession: Bool {
        guard catalogSeesSessionDDL else { return false }
        return !appState.catalogChanges.sessionLeftCatalog(
            for: connection.id, driver: session.map { ObjectIdentifier($0.driver) }
        )
    }

    var transactionToken: SessionTransactionMonitor.HoldToken? {
        appState.sessionTransactions.token(for: connection.id, on: session?.driver)
    }

    // `reading` work is a read the app built, so a session lost under it cannot have committed anything.
    func track<T>(
        reading: Bool = false,
        failed: (T) -> Bool = { _ in false },
        rolledBack: (T) -> Bool = { _ in false },
        _ work: () async throws -> T
    ) async rethrows -> T {
        let heldBefore = transactionHold != nil
        let loss: SessionLoss = reading ? .whileIdle : .duringWork
        do {
            let value = try await appState.sessionTransactions.track(connection.id, reading: reading, work)
            var lossSettled = false
            if failed(value) {
                lossSettled = await restoreSession(after: loss)
            }
            // A typed ROLLBACK leaves what grids and row screens read as stale as the bar's Roll Back does.
            // AND CHAIN, or a script that opens another after its ROLLBACK, ends with a transaction open.
            if heldBefore, !lossSettled, rolledBack(value) {
                appState.sessionTransactions.noteRolledBack(connection.id)
            }
            await reloadMetadataIfReleased()
            return value
        } catch {
            await restoreSession(after: loss)
            throw error
        }
    }

    // A list reload reading the session would end the page with its next statement, so the page waits for it; nothing
    // suspends between that wait and `track` marking the session busy. A page that fails on a dead session redials,
    // and the browser reloads on the new one.
    func trackPageRead(failed: @escaping @MainActor () -> Bool) -> DataBrowserViewModel.SessionReadTracker {
        let catalogChanges = appState.catalogChanges
        let connectionId = connection.id
        return { [weak self] read in
            await catalogChanges.sessionReadsFinished(for: connectionId)
            guard let self else {
                await read()
                return
            }
            await self.track(reading: true, failed: { _ in failed() }) { await read() }
        }
    }

    // The token is what the indicator showed when the user asked, so a swapped session or newer work refuses.
    func commitTransaction(as token: SessionTransactionMonitor.HoldToken) async throws {
        do {
            try await appState.sessionTransactions.commit(connection.id, as: token)
        } catch {
            guard await !restoreSession(after: .duringWork) else { return }
            throw error
        }
        await reloadMetadataIfReleased()
        // A catalog connection sees DDL the transaction ran only once it commits.
        noteCatalogChanged([.tables, .schemas, .databases])
    }

    func rollBackTransaction(as token: SessionTransactionMonitor.HoldToken) async throws {
        do {
            try await appState.sessionTransactions.rollBack(connection.id, as: token)
        } catch {
            guard await !restoreSession(after: .duringRollBack) else { return }
            throw error
        }
        await reloadMetadataIfReleased()
        // The lists may show a schema or a database the rolled-back transaction created.
        noteCatalogChanged([.schemas, .databases])
    }

    func refreshTransaction() async {
        await appState.sessionTransactions.refresh(connection.id)
    }

    // A Roll Back from any window can undo DDL; a failed read keeps the list it has.
    func reloadAfterRollBack() async {
        guard !metadataRefused else {
            await reloadMetadataIfReleased()
            return
        }
        guard let session else { return }
        do {
            let reloaded = try await session.driver.fetchTables(schema: supportsSchemas ? activeSchema : nil)
            guard self.session?.driver === session.driver else { return }
            tables = reloaded
        } catch {
            Self.logger.warning("Failed to reload tables after a Roll Back: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        // With autocommit off, a MySQL read opens a transaction.
        await refreshTransaction()
    }

    private func reloadMetadataIfReleased() async {
        guard metadataRefused, let session,
              appState.sessionTransactions.hold(for: connection.id, on: session.driver) == nil else { return }
        do {
            let reloaded = try await session.driver.fetchTables(schema: nil)
            guard self.session?.driver === session.driver else { return }
            tables = reloaded
            metadataRefused = false
        } catch {
            Self.logger.warning("Tables are still refused: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return
        }
        await loadDatabases()
        await loadSchemas()
    }

    // MARK: - Database / Schema Switching

    // A MongoDB `use` moves the session itself, so the lists and the picker follow it there, once every request queued
    // before has returned: a request Stop ended lands its `use` only then. The switch runs outside the run that asks,
    // which Stop may have cancelled. While another window holds unsaved edits the session goes back instead, so they
    // save where the picker says.
    func followSessionDatabase() async {
        guard supportsDatabaseSwitching, let driver = session?.driver as? PluginBackedDriver else { return }
        await Task {
            guard let used = try? await driver.settledCurrentDatabase(), used != activeDatabase,
                  session?.driver === driver else { return }
            guard !anotherWindowHoldsEditor else {
                try? await driver.switchDatabase(to: activeDatabase)
                presentFailure(title: Self.switchDatabaseFailedTitle, message: Self.editorHeldElsewhereMessage)
                return
            }
            await switchDatabase(to: used)
        }.value
    }

    func switchDatabase(to name: String) async {
        guard session != nil, name != activeDatabase, !isSwitching else { return }
        guard !anotherWindowHoldsEditor else {
            presentFailure(title: Self.switchDatabaseFailedTitle, message: Self.editorHeldElsewhereMessage)
            return
        }
        let failure = await whileSwitching(to: name) {
            let failure: Failure?
            if connection.type == .postgresql || connection.type == .redshift {
                await reconnectWithDatabase(name)
                failure = nil
            } else {
                failure = await useDatabase(name)
            }
            await refreshTransaction()
            appState.bumpSessionRevision(connection.id)
            return failure
        }
        guard let failure else { return }
        await report(failure, operation: "switchDatabase")
    }

    private func useDatabase(_ name: String) async -> Failure? {
        do {
            try await appState.connectionManager.switchDatabase(connection.id, to: name)
        } catch {
            return Failure(error: error, title: Self.switchDatabaseFailedTitle, redialRepeats: false)
        }
        if let freshSession = appState.connectionManager.session(for: connection.id) {
            self.session = freshSession
        }
        UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id))
        do {
            let fetched = try await session?.driver.fetchTables(schema: nil) ?? []
            // Placement and tables change in one step, so a row of the old list never pairs with the new database.
            activeDatabase = name
            tables = fetched
            return nil
        } catch {
            // The session is on the new database either way, so its list empties until a reload can read it.
            activeDatabase = name
            metadataRefused = true
            tables = []
            return Failure(error: error, title: Self.refreshTablesFailedTitle, redialRepeats: true)
        }
    }

    // Lets another window's redial land before the teardown that would cancel it, and dials where other windows join.
    private func reconnectWithDatabase(_ database: String) async {
        let token = attemptToken
        await appState.sessionRedialer.settled(connection.id)
        // A window closed during that wait must not tear down the session the other windows now use.
        guard attemptToken == token else { return }
        let previous = dialTarget
        await appState.connectionManager.disconnect(connection.id)
        self.session = nil

        var newConnection = connection
        newConnection.database = database

        do {
            let newSession = try await appState.sessionRedialer.redial(
                newConnection,
                schema: nil,
                prompter: prompts,
                joining: false,
                consumer: self,
                stillWanted: { [weak self] in self?.attemptToken == token }
            ).session
            guard attemptToken == token else { return }
            let fetched = try await newSession.driver.fetchTables(schema: nil)
            guard attemptToken == token else { return }
            self.session = newSession
            self.tables = fetched
            activeDatabase = database
            UserDefaults.standard.set(database, forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id))
            await loadSchemas()
        } catch {
            guard attemptToken == token else { return }
            Self.logger.error("Failed to switch to database \(database, privacy: .private(mask: .hash)): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            // Back to the database the picker still shows, not the saved one, so the picker stays true.
            do {
                let fallback = try await appState.sessionRedialer.redial(
                    previous,
                    schema: supportsSchemas ? activeSchema : nil,
                    prompter: prompts,
                    joining: false,
                    consumer: self,
                    stillWanted: { [weak self] in self?.attemptToken == token }
                )
                guard attemptToken == token else { return }
                await takeSession(fallback.session, token: token, dialedHere: fallback.dialedHere)
                guard attemptToken == token else { return }
                presentFailure(
                    title: Self.switchDatabaseFailedTitle,
                    message: classify(error, operation: "switchDatabase").message
                )
            } catch {
                guard attemptToken == token else { return }
                phase = .lost(classify(error, operation: "switchDatabase"))
                self.session = nil
            }
        }
    }

    func switchSchema(to name: String) async {
        guard let session, name != activeSchema, !isSwitching else { return }
        let failure = await whileSwitching(to: name) {
            do {
                try await session.driver.switchSchema(to: name)
            } catch {
                return Failure(error: error, title: Self.switchSchemaFailedTitle, redialRepeats: false)
            }
            UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastSchema.name(for: connection.id))
            appState.bumpSessionRevision(connection.id)
            do {
                let fetched = try await session.driver.fetchTables(schema: name)
                activeSchema = name
                tables = fetched
                return nil
            } catch {
                activeSchema = name
                metadataRefused = true
                tables = []
                return Failure(error: error, title: Self.refreshTablesFailedTitle, redialRepeats: true)
            }
        }
        guard let failure else { return }
        await report(failure, operation: "switchSchema")
    }

    private func whileSwitching(to target: String, _ work: () async -> Failure?) async -> Failure? {
        switchTarget = target
        isSwitching = true
        defer {
            isSwitching = false
            switchTarget = nil
        }
        return await work()
    }

    private struct Failure {
        let error: any Error
        let title: String
        // A failed read that a redial repeats needs no alert once the redial lands.
        let redialRepeats: Bool
    }

    // A failure on a dead session redials first. The alert then says why, unless the session is lost, which its own
    // screen says.
    private func report(_ failure: Failure, operation: String) async {
        let failedOn = session?.driver
        if await restoreSession(after: .whileIdle) { return }
        guard !isLost, !failure.redialRepeats || session?.driver === failedOn else { return }
        presentFailure(title: failure.title, message: classify(failure.error, operation: operation).message)
    }

    func presentFailure(title: String?, message: String) {
        failureAlertTitle = title
        failureAlertMessage = message
        showFailureAlert = true
    }

    static var switchDatabaseFailedTitle: String { String(localized: "Failed to switch database") }
    static var switchSchemaFailedTitle: String { String(localized: "Failed to switch schema") }
    static var refreshTablesFailedTitle: String { String(localized: "Failed to refresh tables") }

    // MARK: - Tables

    func refreshTables() async {
        guard let session else { return }
        do {
            let schema = supportsSchemas ? activeSchema : nil
            self.tables = try await session.driver.fetchTables(schema: schema)
        } catch {
            Self.logger.warning("Failed to refresh tables: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            await report(Failure(error: error, title: Self.refreshTablesFailedTitle, redialRepeats: true), operation: "refreshTables")
        }
        // With autocommit off, a MySQL read opens a transaction.
        await refreshTransaction()
    }

    // MARK: - Catalog Changes

    // `reloadedHere`: the caller already read the session, the one place a transaction's own DDL shows.
    func noteCatalogChanged(_ kinds: SQLCatalogObjectKinds, reloadedHere: Bool = false) {
        let board = appState.catalogChanges
        let caughtUp = board.generation(for: connection.id) == seenCatalogGeneration
        board.post(kinds, for: connection.id)
        if reloadedHere, caughtUp {
            seenCatalogGeneration = board.generation(for: connection.id)
        }
    }

    // A statement a window ran may have created or dropped what the lists show; failed reads keep the lists.
    // One reload at a time: a later post waits for it, so an older answer never lands over a newer one.
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
        let generation = board.generation(for: connection.id)
        guard generation != seenCatalogGeneration, let session, !isSwitching else { return }
        var wanted = board.kinds(for: connection.id, since: seenCatalogGeneration)
        if !supportsSchemas { wanted.remove(.schemas) }
        if !supportsDatabaseSwitching { wanted.remove(.databases) }
        let kinds = wanted
        let database = supportsDatabaseSwitching ? activeDatabase : ""
        let schema = supportsSchemas ? activeSchema : nil
        let place = CatalogPlace(driver: ObjectIdentifier(session.driver), database: activeDatabase, schema: activeSchema)
        let monitor = appState.sessionTransactions

        var snapshot: CatalogSnapshot?
        // On the session a read would replace ROW_COUNT() and the warnings, so it is only where the DDL is visible, or
        // where a USE or a role moved the session off what the catalog connection sees, as Refresh reads it there too.
        if catalogMatchesSession {
            do {
                snapshot = try await appState.connectionManager.readCatalog(for: connection.id, database: database) {
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
            if catalogMatchesSession, appState.connectionManager.opensCatalogConnections(for: connection.id) {
                seenCatalogGeneration = generation
                return
            }
            // A stream on the session would end under this read, so it waits for the session to go idle.
            guard !monitor.isBusy(connection.id) else { return }
            board.beginSessionRead(for: connection.id)
            snapshot = try? await monitor.track(connection.id, reading: true) {
                try await Self.readCatalog(kinds, schema: schema, from: session.driver)
            }
            board.endSessionRead(for: connection.id)
        }
        seenCatalogGeneration = generation
        guard let snapshot, place == CatalogPlace(
            driver: self.session.map { ObjectIdentifier($0.driver) }, database: activeDatabase, schema: activeSchema
        ) else { return }
        if let reloaded = snapshot.tables { tables = reloaded }
        if let reloaded = snapshot.schemas { schemas = reloaded }
        if let reloaded = snapshot.databases { databases = reloaded }
    }

    private struct CatalogPlace: Equatable {
        let driver: ObjectIdentifier?
        let database: String
        let schema: String
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

    // MARK: - Query History

    func loadHistory() {
        queryHistory = historyStorage.load(for: connection.id)
    }

    func addHistoryItem(_ item: QueryHistoryItem) {
        guard historyStorage.save(item) else { return }
        loadHistory()
    }

    func deleteHistoryItem(_ id: UUID) {
        historyStorage.delete(id)
        queryHistory.removeAll { $0.id == id }
    }

    func clearHistory() {
        historyStorage.clearAll(for: [connection.id])
        queryHistory = []
    }

    func navigateToPendingTable() {
        guard let table = TableSelectionResolver.resolve(pendingName: pendingTableName, in: tables) else { return }
        pendingTableName = nil
        selectedTab = .tables
        selectedTable = table
    }

    // MARK: - Private Helpers

    private func loadDatabases() async {
        guard let session, supportsDatabaseSwitching else { return }
        do {
            databases = try await session.driver.fetchDatabases()
            if !activeDatabase.isEmpty, databases.contains(activeDatabase) {
                let sessionDB = appState.connectionManager.session(for: connection.id)?.activeDatabase ?? connection.database
                if activeDatabase != sessionDB {
                    let target = activeDatabase
                    activeDatabase = sessionDB
                    await switchDatabase(to: target)
                }
            } else {
                activeDatabase = appState.connectionManager.session(for: connection.id)?.activeDatabase ?? connection.database
                // A database the connection names by its id is listed by its name, which the driver reports.
                if !databases.contains(activeDatabase), let reported = session.driver.currentDatabase,
                   databases.contains(reported) {
                    await switchDatabase(to: reported)
                }
            }
        } catch {
            Self.logger.warning("Failed to load databases: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadSchemas() async {
        guard let session, supportsSchemas else { return }
        do {
            schemas = try await session.driver.fetchSchemas()
            let currentSchema = session.driver.currentSchema ?? "public"
            if schemas.contains(activeSchema), activeSchema != currentSchema {
                let target = activeSchema
                activeSchema = currentSchema
                await switchSchema(to: target)
            } else if !schemas.contains(activeSchema) {
                activeSchema = currentSchema
            }
        } catch {
            Self.logger.warning("Failed to load schemas: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}
