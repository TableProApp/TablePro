import Foundation
import Observation
import os
import SwiftUI
import TableProDatabase
import TableProModels

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
        case connecting
        case connected
        case error(AppError)
    }

    var displayName: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    var supportsDatabaseSwitching: Bool {
        connection.type == .mysql || connection.type == .mariadb ||
        connection.type == .tidb || connection.type == .oceanbase ||
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql || connection.type == .clickhouse
    }

    var supportsSchemas: Bool {
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql || connection.type == .duckdb ||
        connection.type == .oracle
    }

    init(connection: DatabaseConnection, appState: AppState) {
        self.connection = connection
        self.appState = appState
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

    /// The attempt allowed to write `session` and `phase`. Cancelling mints a new one.
    private var attemptToken = UUID()
    private var connectTask: Task<Void, Never>? {
        didSet { resumeFollowIfPending() }
    }

    private var joiners = AttemptJoiners()

    /// Questions this attempt has to ask, shown by the screen that owns the attempt.
    let prompts = ConnectionPromptQueue()

    /// Returning early without touching `phase` is what left the connecting screen up for good.
    func connect() async {
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

    /// A caller that goes away mid-connect (its screen was dismissed) abandons the attempt rather
    /// than leaving it running for the next screen to join and wait on forever.
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

    /// Never waits on the driver: `Task.cancel()` is cooperative and these drivers ignore it.
    ///
    /// The questions go first and unconditionally: a reconnect or a database switch asks them
    /// without owning `connectTask`, and leaving one suspended holds its tunnel open for good.
    func cancelConnect() {
        prompts.cancelAll()
        guard connectTask != nil else { return }
        retire()
        phase = .error(Self.cancelledError)
    }

    private static var cancelledError: AppError {
        AppError(
            category: .network,
            title: String(localized: "Connection Cancelled"),
            message: String(localized: "The connection attempt was cancelled."),
            recovery: String(localized: "Tap Retry to try again."),
            underlying: nil
        )
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

    /// `allowSignIn` is false on the retry that follows a sign-in, so a connection that keeps
    /// failing cannot put the prompt up again and again. That retry dials with the new credentials
    /// rather than join a dial another window started without them.
    private func connectFresh(token: UUID, allowSignIn: Bool = true) async {
        IOSAnalyticsProvider.shared.markConnectionAttempted()

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
            IOSAnalyticsProvider.shared.markConnectionSucceeded()
            navigateToPendingTable()
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
            let context = ErrorContext(
                operation: "connect",
                databaseType: connection.type,
                host: connection.host,
                sshEnabled: connection.sshEnabled,
                signsInWithIAM: connection.iamSignIn != nil
            )
            phase = .error(ErrorClassifier.classify(failure, context: context))
        }
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
        guard let session, !isSwitching, !isReconnecting, connectTask == nil else { return false }
        let token = attemptToken
        var workWasRunning = appState.sessionTransactions.isBusy(connection.id)

        if await takesNewerSession(than: session, token: token) { return false }
        if appState.connectionManager.session(for: connection.id) != nil, await Self.answersPing(session.driver) {
            return false
        }
        guard attemptToken == token else { return false }
        // Another window can finish a whole redial while this ping is out.
        if await takesNewerSession(than: session, token: token) { return false }

        workWasRunning = workWasRunning || appState.sessionTransactions.isBusy(connection.id)
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
            guard attemptToken == token, heldTransaction else { return false }
            appState.sessionTransactions.noteRolledBack(connection.id)
            let settledLoss: SessionLoss = workWasRunning || statementFailedDuringCheck ? .duringWork : loss
            if let message = Self.lostTransactionMessage(settledLoss, connectionName: displayName) {
                failureAlertMessage = message
                showFailureAlert = true
            }
            return true
        } catch {
            guard attemptToken == token else { return false }
            let context = ErrorContext(
                operation: "reconnect",
                databaseType: connection.type,
                host: connection.host,
                sshEnabled: connection.sshEnabled,
                signsInWithIAM: connection.iamSignIn != nil
            )
            phase = .error(ErrorClassifier.classify(error, context: context))
            self.session = nil
            return false
        }
    }

    private func takesNewerSession(than held: ConnectionSession, token: UUID) async -> Bool {
        // A redial another window started is not ready to share until its schema is back.
        await appState.sessionRedialer.settled(connection.id, consumer: self, prompter: prompts)
        guard attemptToken == token,
              let live = appState.connectionManager.session(for: connection.id),
              live.driver !== held.driver else {
            return false
        }
        await takeSession(live, token: token, dialedHere: false)
        return true
    }

    private var dialTarget: DatabaseConnection {
        guard supportsDatabaseSwitching, !activeDatabase.isEmpty else { return connection }
        var target = connection
        target.database = activeDatabase
        return target
    }

    private func takeSession(_ newSession: ConnectionSession, token: UUID, dialedHere: Bool) async {
        let fetched: [TableInfo]?
        do {
            fetched = try await newSession.driver.fetchTables(schema: nil)
        } catch {
            Self.logger.warning("Failed to load tables on the new session: \(error.localizedDescription, privacy: .public)")
            fetched = nil
        }
        guard attemptToken == token else { return }
        // The dial restored this window's schema, or another window's; a failed restore leaves the default.
        let movedPlacement = adoptPlacement(of: newSession, includingDatabase: !dialedHere)
        if let fetched {
            tables = fetched
        } else {
            metadataRefused = true
            if movedPlacement { tables = [] }
        }
        session = newSession
        if dialedHere {
            appState.bumpSessionRevision(connection.id)
        }
        await refreshTransaction()
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
            await takeSession(live, token: token, dialedHere: false)
            guard attemptToken == token else { return }
            await loadSchemas()
            return
        }
        let moved = movedPlacement(of: live, includingDatabase: true)
        guard moved.database != nil || moved.schema != nil else { return }
        let fetched: [TableInfo]?
        do {
            fetched = try await live.driver.fetchTables(schema: supportsSchemas ? moved.schema ?? activeSchema : nil)
        } catch {
            Self.logger.warning("Failed to load tables where another window moved the session: \(error.localizedDescription, privacy: .public)")
            fetched = nil
        }
        guard attemptToken == token, session?.driver === live.driver else { return }
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
        session != nil && !isSwitching && !isReconnecting && connectTask == nil && !isHeldByEditor
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
        Self.logger.info("Kept a session that refused its catalog: \(refusal.localizedDescription, privacy: .public)")
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

    var transactionToken: SessionTransactionMonitor.HoldToken? {
        appState.sessionTransactions.token(for: connection.id, on: session?.driver)
    }

    func track<T>(
        failed: (T) -> Bool = { _ in false },
        rolledBack: (T) -> Bool = { _ in false },
        _ work: () async throws -> T
    ) async rethrows -> T {
        let heldBefore = transactionHold != nil
        do {
            let value = try await appState.sessionTransactions.track(connection.id, work)
            var lossSettled = false
            if failed(value) {
                lossSettled = await restoreSession(after: .duringWork)
            }
            // A typed ROLLBACK leaves what grids and row screens read as stale as the bar's Roll Back does.
            // AND CHAIN, or a script that opens another after its ROLLBACK, ends with a transaction open.
            if heldBefore, !lossSettled, rolledBack(value) {
                appState.sessionTransactions.noteRolledBack(connection.id)
            }
            await reloadMetadataIfReleased()
            return value
        } catch {
            await restoreSession(after: .duringWork)
            throw error
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
    }

    func rollBackTransaction(as token: SessionTransactionMonitor.HoldToken) async throws {
        do {
            try await appState.sessionTransactions.rollBack(connection.id, as: token)
        } catch {
            guard await !restoreSession(after: .duringRollBack) else { return }
            throw error
        }
        await reloadMetadataIfReleased()
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
            Self.logger.warning("Failed to reload tables after a Roll Back: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.warning("Tables are still refused: \(error.localizedDescription, privacy: .public)")
            return
        }
        await loadDatabases()
        await loadSchemas()
    }

    // MARK: - Database / Schema Switching

    func switchDatabase(to name: String) async {
        guard session != nil, name != activeDatabase, !isSwitching else { return }
        guard !anotherWindowHoldsEditor else {
            failureAlertMessage = Self.editorHeldElsewhereMessage
            showFailureAlert = true
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        if connection.type == .postgresql || connection.type == .redshift {
            await reconnectWithDatabase(name)
        } else {
            do {
                try await appState.connectionManager.switchDatabase(connection.id, to: name)
                if let freshSession = appState.connectionManager.session(for: connection.id) {
                    self.session = freshSession
                }
                activeDatabase = name
                UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id))
                if let current = self.session {
                    self.tables = try await current.driver.fetchTables(schema: nil)
                }
            } catch {
                failureAlertMessage = String(localized: "Failed to switch database")
                showFailureAlert = true
            }
        }
        await refreshTransaction()
        appState.bumpSessionRevision(connection.id)
    }

    // Lets another window's redial land before the teardown that would cancel it, and dials where other windows join.
    private func reconnectWithDatabase(_ database: String) async {
        let token = attemptToken
        await appState.sessionRedialer.settled(connection.id)
        // A window closed during that wait must not tear down the session the other windows now use.
        guard attemptToken == token else { return }
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
            self.session = newSession
            self.tables = try await newSession.driver.fetchTables(schema: nil)
            activeDatabase = database
            UserDefaults.standard.set(database, forKey: ConnectionDefaultsKey.lastDB.name(for: connection.id))
            await loadSchemas()
        } catch {
            guard attemptToken == token else { return }
            Self.logger.error("Failed to switch to database \(database, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                let fallbackSession = try await appState.sessionRedialer.redial(
                    connection,
                    schema: nil,
                    prompter: prompts,
                    joining: false,
                    consumer: self,
                    stillWanted: { [weak self] in self?.attemptToken == token }
                ).session
                guard attemptToken == token else { return }
                self.session = fallbackSession
                self.tables = try await fallbackSession.driver.fetchTables(schema: nil)
                failureAlertMessage = String(localized: "Failed to switch database")
                showFailureAlert = true
            } catch {
                guard attemptToken == token else { return }
                let context = ErrorContext(
                    operation: "switchDatabase",
                    databaseType: connection.type,
                    host: connection.host,
                    sshEnabled: connection.sshEnabled,
                    signsInWithIAM: connection.iamSignIn != nil
                )
                phase = .error(ErrorClassifier.classify(error, context: context))
                self.session = nil
            }
        }
    }

    func switchSchema(to name: String) async {
        guard let session, name != activeSchema, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        do {
            try await session.driver.switchSchema(to: name)
            activeSchema = name
            UserDefaults.standard.set(name, forKey: ConnectionDefaultsKey.lastSchema.name(for: connection.id))
            appState.bumpSessionRevision(connection.id)
            self.tables = try await session.driver.fetchTables(schema: name)
        } catch {
            failureAlertMessage = String(localized: "Failed to switch schema")
            showFailureAlert = true
        }
    }

    // MARK: - Tables

    func refreshTables() async {
        guard let session else { return }
        do {
            let schema = supportsSchemas ? activeSchema : nil
            self.tables = try await session.driver.fetchTables(schema: schema)
        } catch {
            Self.logger.warning("Failed to refresh tables: \(error.localizedDescription, privacy: .public)")
            failureAlertMessage = String(localized: "Failed to refresh tables")
            showFailureAlert = true
        }
        // With autocommit off, a MySQL read opens a transaction.
        await refreshTransaction()
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
            } else if let stored = appState.connectionManager.session(for: connection.id) {
                activeDatabase = stored.activeDatabase
            } else {
                activeDatabase = connection.database
            }
        } catch {
            Self.logger.warning("Failed to load databases: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.warning("Failed to load schemas: \(error.localizedDescription, privacy: .public)")
        }
    }
}
