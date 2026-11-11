import Foundation
import Observation
import os
import SwiftUI
import TableProConnectionLibrary
import TableProDatabase
import TableProModels
import TableProSQLGrammar

// One window's view of a connection. The session, its lists and its lifecycle are the connection's
// `ConnectionSessionModel`, shared by every window; this keeps what is the window's own and asks the model for the rest.
@MainActor @Observable
final class ConnectionCoordinator {
    private let model: ConnectionSessionModel
    private let appState: AppState

    // False until the window connects, and again once it walks away: it then shows no session, whatever the model
    // still holds for other windows.
    private(set) var isAttached = false
    // What the window showed when the session moved under its unsaved edit; it stays there until the edit ends.
    private var pin: ConnectionSnapshot?

    var connection: DatabaseConnection { model.record }
    var session: ConnectionSession? { isAttached ? shownState.session : nil }
    var phase: ConnectionPhase { isAttached ? shownState.phase : .notConnected }
    var isReconnecting: Bool { isAttached && shownState.isReconnecting }
    var tables: [TableInfo] { shownCatalog.tables }
    var databases: [String] { shownCatalog.databases }
    var schemas: [String] { shownCatalog.schemas }
    var activeDatabase: String { shownCatalog.placement.database }
    var activeSchema: String { shownCatalog.placement.schema }

    private var shownState: ConnectionSessionState { pin?.state ?? model.state }
    private var shownCatalog: ConnectionCatalog { pin?.catalog ?? model.catalog }

    private(set) var isSwitching = false
    private(set) var switchTarget: String?
    // A move of the session would rebuild the table screen, which would drop an unsaved row edit.
    var isHeldByEditor = false {
        didSet {
            guard isHeldByEditor != oldValue else { return }
            appState.setEditorHold(isHeldByEditor, by: self, on: connection.id)
            guard !isHeldByEditor, pin != nil else { return }
            pin = nil
            selectedTable = TableSelectionResolver.keeping(selectedTable, in: tables)
            resumedFollow = Task { await followLiveSession() }
        }
    }

    var anotherWindowHoldsEditor: Bool {
        appState.holdsEditor(connection.id, besides: self)
    }

    @ObservationIgnored private(set) var resumedFollow: Task<Void, Never>?
    @ObservationIgnored private var joiners = AttemptJoiners()
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
    private(set) var keepsDamagedHistoryCopy = false
    @ObservationIgnored private var historyGeneration = 0
    private var historyStorage: QueryHistoryStorage { appState.queryHistory }

    var connectionManager: ConnectionManager { appState.connectionManager }

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

    var displayName: String { model.displayName }
    var supportsDatabaseSwitching: Bool { model.supportsDatabaseSwitching }
    var supportsSchemas: Bool { model.supportsSchemas }

    init(connection: DatabaseConnection, appState: AppState) {
        self.appState = appState
        model = appState.sessionModels.model(for: connection, appState: appState)
        model.register(self)
    }

    // MARK: - Persisted State

    func restorePersistedState() {
        let defaults = UserDefaults.standard
        if let savedTab = defaults.string(forKey: ConnectionDefaultsKey.lastTab.name(for: connection.id)),
           let tab = ConnectedTab(rawValue: savedTab) {
            selectedTab = tab
        }
        model.restorePersistedPlacement()
    }

    // MARK: - Connection Lifecycle

    let prompts = ConnectionPromptQueue()

    // The last caller to go away walks the window away, so a screen that closed mid-open leaves nothing waiting.
    func connect() async {
        prompts.expectScreen()
        isAttached = true
        let joiner = joiners.join()
        await withTaskCancellationHandler {
            await model.connect(from: self)
            _ = joiners.leave(joiner)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, joiners.leave(joiner), case .connecting = phase else { return }
                cancelConnect()
            }
        }
        await model.runHeldBackWork(from: self)
    }

    func adopt(_ record: DatabaseConnection) {
        model.adopt(record)
    }

    func retire() {
        isAttached = false
        pin = nil
        prompts.cancelAll()
        if appState.sessionRedialer.leave(connection.id, consumer: self) {
            appState.connectionManager.invalidateAttempt(for: connection.id)
        }
        appState.setEditorHold(false, by: self, on: connection.id)
        model.leave(self)
    }

    // The record changed how it dials, so no window keeps the session.
    func dropSession() {
        model.reset()
    }

    // Never waits on the driver, which ignores `Task.cancel()`. The questions go first: a reconnect or a
    // database switch asks without being the open, and a suspended one holds its tunnel open.
    func cancelConnect() {
        prompts.cancelAll()
        guard isAttached, model.state.isOpening || (isLost && isReconnecting) else { return }
        retire()
    }

    // A lost session redials where it was, so the screen of a row edit in progress is not rebuilt.
    func reconnect() async {
        if isLost {
            await restoreSession(after: .whileIdle)
        } else {
            await connect()
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
        // The app closed a database file as it went to the background, which rolled the transaction back.
        case inBackground
        // The app closed the file once a running statement ended, and that statement may have ended the transaction.
        case inBackgroundAfterStatement
    }

    // True when the redial dropped a held transaction and the outcome is already settled for the user.
    @discardableResult
    private func restoreSession(after loss: SessionLoss) async -> Bool {
        guard isAttached else { return false }
        let settled = await model.restoreSession(after: loss, from: self)
        await model.runHeldBackWork(from: self)
        return settled
    }

    // An unsaved edit belongs to the placement it was made in, so while it is open the window keeps what it showed
    // when the session moved elsewhere: taking it would rebuild the editor's screen, or point its save at a same-named
    // table in another database. A move this window asked for itself reaches it.
    func sessionModelChanged(from old: ConnectionSnapshot) {
        guard pin == nil else { return }
        if isHeldByEditor, !isSwitching, model.moves(from: old) {
            // An open or a switch in flight is not where the edit was made; the loss or session before it is.
            pin = ConnectionSnapshot(state: old.state.atRest, catalog: old.catalog)
            return
        }
        guard old.catalog.tables != model.catalog.tables else { return }
        selectedTable = TableSelectionResolver.keeping(selectedTable, in: model.catalog.tables)
    }

    // It shows the model's session and no edit holds it, so it can hear what the model does for every window.
    var showsLiveSession: Bool {
        isAttached && pin == nil && !isHeldByEditor
    }

    // The manager's session moved, or another party replaced it.
    func followLiveSession() async {
        guard isAttached, pin == nil else { return }
        await model.follow(from: self)
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
            schema: tableQualifier
        )
    }

    // What the Tables tab qualifies a table with. MySQL's `db`.`table` names the database where other engines name a
    // schema, so a `USE` run in the Query tab never moves where a browse, a save or a drop lands.
    var tableQualifier: String? {
        if supportsSchemas { return activeSchema }
        guard model.qualifiesTablesWithDatabase, !activeDatabase.isEmpty else { return nil }
        return activeDatabase
    }

    static var editorHeldElsewhereMessage: String {
        String(localized: "Another window has unsaved changes on this connection. Save or discard them before switching database.")
    }

    static var editorHeldHereMessage: String {
        String(localized: "This window has unsaved changes on this connection, so the session stayed on its database. Save or discard them before switching database.")
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
        case .inBackground:
            String(
                format: String(
                    localized: "TablePro closed %@ when it went to the background, which rolled back its open transaction. It has been reopened; run the statements again, and commit before you leave the app."
                ),
                connectionName
            )
        case .inBackgroundAfterStatement:
            String(
                format: String(
                    localized: "TablePro closed %@ when it went to the background while a statement was running, so its open transaction may have been committed or rolled back. It has been reopened; check which of its changes were saved before running them again."
                ),
                connectionName
            )
        }
    }

    // MARK: - Transactions

    var transactionHold: SessionTransactionMonitor.Hold? {
        appState.sessionTransactions.hold(for: connection.id, on: session?.driver)
    }

    var catalogSeesSessionDDL: Bool {
        model.catalogSeesSessionDDL(on: session?.driver)
    }

    var catalogMatchesSession: Bool {
        model.catalogMatchesSession(on: session?.driver)
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
            await model.reloadMetadataIfReleased(from: self)
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
        await model.reloadMetadataIfReleased(from: self)
        // A catalog connection sees DDL the transaction ran only once it commits.
        noteCatalogChanged([.tables, .schemas, .databases])
        // A `SET LOCAL search_path` ends with the transaction.
        await followSessionSchema()
    }

    func rollBackTransaction(as token: SessionTransactionMonitor.HoldToken) async throws {
        do {
            try await appState.sessionTransactions.rollBack(connection.id, as: token)
        } catch {
            guard await !restoreSession(after: .duringRollBack) else { return }
            throw error
        }
        await model.reloadMetadataIfReleased(from: self)
        // The lists may show a schema or a database the rolled-back transaction created.
        noteCatalogChanged([.schemas, .databases])
    }

    func refreshTransaction() async {
        await model.refreshTransaction()
    }

    // A Roll Back from any window can undo DDL.
    func reloadAfterRollBack() async {
        guard isAttached else { return }
        await model.reloadAfterRollBack(from: self)
    }

    // MARK: - Database / Schema Switching

    // What a run may have moved: a `USE` moves the database, and a search path, a role or a transaction's end the schema.
    struct SessionMove {
        var database = false
        var schema = false
    }

    // A read that costs a statement replaces ROW_COUNT() and the warnings, so it is sent only after a run that can have
    // moved the session. The work runs in a task of its own, since Stop may have cancelled the run that asks.
    func followSessionPlacement(after move: SessionMove) async {
        await followSessionDatabase(after: move)
        if move.schema { await followSessionSchema() }
    }

    private func followSessionDatabase(after move: SessionMove) async {
        guard supportsDatabaseSwitching, let driver = session?.driver as? any SessionDatabaseReporting,
              move.database || driver.reportsDatabaseWithoutStatement else { return }
        await Task {
            let used = try? await driver.sessionDatabase()
            // With autocommit off, a MySQL read opens a transaction.
            if !driver.reportsDatabaseWithoutStatement { await refreshTransaction() }
            guard let used, !used.isEmpty, used != activeDatabase, session?.driver === driver else { return }
            // An unsaved edit holds the session where it was made, as it holds the picker.
            if isHeldByEditor || anotherWindowHoldsEditor, !activeDatabase.isEmpty {
                let back = activeDatabase
                let failure = await whileSwitching(to: back) {
                    do {
                        try await driver.switchDatabase(to: back)
                        return nil
                    } catch {
                        return ConnectionFailure(error: error, title: Self.switchDatabaseFailedTitle, redialRepeats: false)
                    }
                }
                guard failure != nil else {
                    presentFailure(
                        title: Self.switchDatabaseFailedTitle,
                        message: isHeldByEditor ? Self.editorHeldHereMessage : Self.editorHeldElsewhereMessage
                    )
                    return
                }
                // The lists follow the session, and every window with an edit open keeps the database it was made in,
                // this one too, since it did not ask for the move.
                model.beginSwitch()
                _ = await model.switchDatabase(to: used, from: self, inside: nil)
                model.endSwitch()
                await model.loadSchemasAfterSwitch(to: used, from: self)
                await model.runHeldBackWork(from: self)
                // MySQL names the database in every Tables tab write; SQL Server saves only once the session is back.
                presentFailure(
                    title: Self.switchDatabaseFailedTitle,
                    message: model.qualifiesTablesWithDatabase
                        ? String(format: String(localized: "The query moved the session to “%@” and it could not go back to “%@”. Unsaved changes still save to “%@”."), used, back, back)
                        : String(format: String(localized: "The query moved the session to “%@” and it could not go back to “%@”. To save the unsaved changes, run USE %@ in the Query tab of the window that holds them."), used, back, back)
                )
                return
            }
            await switchDatabase(to: used)
        }.value
    }

    // The Tables tab names its schema, so only completion and the picker read where the session is.
    private func followSessionSchema() async {
        guard supportsSchemas, let driver = session?.driver as? any SessionSchemaReporting else { return }
        await driver.settleCurrentSchema()
        guard session?.driver === driver, let current = driver.currentSchema, current != activeSchema else { return }
        appState.bumpSessionRevision(connection.id)
        await followLiveSession()
    }

    // From the start of a run with a `USE` until the picker follows it, another run's statements could go out around the
    // move, so no window runs one, and on SQL Server, whose Tables tab names no database, every window's writes are
    // refused. A driver that reports its database without a statement keeps the app's requests where the picker says.
    func beginDatabaseMove(ifRunning text: String) -> Bool {
        guard supportsDatabaseSwitching, let driver = session?.driver as? any SessionDatabaseReporting,
              !driver.reportsDatabaseWithoutStatement,
              SessionLocalStatements.effect(of: [text], databaseType: connection.type).usesDatabase else { return false }
        model.beginDatabaseMove()
        return true
    }

    func endDatabaseMove() {
        model.endDatabaseMove()
    }

    var isDatabaseMoving: Bool { model.isDatabaseMoving }

    static var databaseMovingRefusal: AppError {
        AppError(
            category: .query,
            title: String(localized: "Database Switch Running"),
            message: String(localized: "A query that switches the database is running on this connection. Try again once it ends."),
            recovery: nil,
            underlying: nil
        )
    }

    var databaseMoveRefusal: AppError? {
        guard supportsDatabaseSwitching, !model.qualifiesTablesWithDatabase,
              let driver = session?.driver as? any SessionDatabaseReporting,
              !driver.reportsDatabaseWithoutStatement else { return nil }
        if model.isDatabaseMoving { return Self.databaseMovingRefusal }
        // A session that could not go back to where an unsaved edit was made. SQL Server compares names by its collation,
        // which ignores case unless set otherwise.
        if let current = driver.currentDatabase, !current.isEmpty, !activeDatabase.isEmpty,
           current.caseInsensitiveCompare(activeDatabase) != .orderedSame {
            return AppError(
                category: .query,
                title: String(localized: "Session in Another Database"),
                message: String(format: String(localized: "The session is in “%@”, not “%@”, so this change cannot be saved now."), current, activeDatabase),
                recovery: nil,
                underlying: nil
            )
        }
        return nil
    }

    func switchDatabase(to name: String) async {
        await switchDatabase(to: name, inside: nil)
    }

    // `open` is the open this switch puts back where the connection was; the switch runs as a step of it.
    func switchDatabase(to name: String, inside open: ConnectionAttempt?) async {
        guard isAttached, session != nil || model.isSwitchingDatabase, name != activeDatabase, !isSwitching else { return }
        guard !anotherWindowHoldsEditor else {
            presentFailure(title: Self.switchDatabaseFailedTitle, message: Self.editorHeldElsewhereMessage)
            return
        }
        let failure = await whileSwitching(to: name) {
            await model.switchDatabase(to: name, from: self, inside: open)
        }
        await model.loadSchemasAfterSwitch(to: name, from: self)
        guard let failure else { return }
        await report(failure, operation: "switchDatabase")
    }

    func switchSchema(to name: String) async {
        guard let session, name != activeSchema, !isSwitching else { return }
        let failure = await whileSwitching(to: name) {
            await model.switchSchema(to: name, on: session)
        }
        guard let failure else { return }
        await report(failure, operation: "switchSchema")
    }

    private func whileSwitching(
        to target: String,
        _ work: () async -> ConnectionFailure?
    ) async -> ConnectionFailure? {
        switchTarget = target
        isSwitching = true
        model.beginSwitch()
        let failure = await work()
        model.endSwitch()
        isSwitching = false
        switchTarget = nil
        await model.runHeldBackWork(from: self)
        return failure
    }

    // A failure on a dead session redials first. The alert then says why, unless the session is lost, which its own
    // screen says.
    func report(_ failure: ConnectionFailure, operation: String) async {
        let failedOn = session?.driver
        if await restoreSession(after: .whileIdle) { return }
        guard !isLost, !failure.redialRepeats || session?.driver === failedOn else { return }
        presentFailure(title: failure.title, message: model.classify(failure.error, operation: operation).message)
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
        guard session != nil else { return }
        if let failure = await model.refreshTables() {
            await report(failure, operation: "refreshTables")
        }
        // With autocommit off, a MySQL read opens a transaction.
        await refreshTransaction()
    }

    // MARK: - Catalog Changes

    // `reloadedHere`: the caller already read the session, the one place a transaction's own DDL shows.
    func noteCatalogChanged(_ kinds: SQLCatalogObjectKinds, reloadedHere: Bool = false) {
        model.noteCatalogChanged(kinds, reloadedHere: reloadedHere)
    }

    func reloadChangedCatalog() async {
        guard isAttached else { return }
        await model.reloadChangedCatalog()
    }

    // MARK: - Query History

    // The file is read and written off the main actor, so a run never waits on it.
    func loadHistory() async {
        let read = await Self.readHistory(for: connection.id, in: historyStorage)
        show(read.listed)
        keepsDamagedHistoryCopy = read.keepsDamagedCopy
    }

    func addHistoryItem(_ item: QueryHistoryItem) async {
        guard let listed = await Self.record(item, in: historyStorage) else { return }
        show(listed)
    }

    // Saves finish in any order; a list read before a later write never replaces what that write left.
    private func show(_ listed: QueryHistoryStorage.Listed) {
        guard listed.generation >= historyGeneration else { return }
        historyGeneration = listed.generation
        queryHistory = listed.items
    }

    @concurrent
    nonisolated private static func readHistory(
        for connectionId: UUID,
        in storage: QueryHistoryStorage
    ) async -> (listed: QueryHistoryStorage.Listed, keepsDamagedCopy: Bool) {
        (storage.listed(for: connectionId), storage.hasSetAsideCopies)
    }

    @concurrent
    nonisolated private static func record(
        _ item: QueryHistoryItem,
        in storage: QueryHistoryStorage
    ) async -> QueryHistoryStorage.Listed? {
        storage.record(item)
    }

    // The row leaves the list at once, as a swipe expects, and the stored list, with any run saved meanwhile, follows.
    @discardableResult
    func deleteHistoryItem(_ id: UUID) -> Task<Void, Never> {
        queryHistory.removeAll { $0.id == id }
        let connectionId = connection.id
        let storage = historyStorage
        return Task {
            let read = await Self.changeHistory(for: connectionId, in: storage) { $0.delete(id) }
            show(read.listed)
        }
    }

    @discardableResult
    func clearHistory() -> Task<Void, Never> {
        let removingSetAside = keepsDamagedHistoryCopy
        let connectionId = connection.id
        let storage = historyStorage
        queryHistory = []
        return Task {
            let read = await Self.changeHistory(for: connectionId, in: storage) { storage in
                storage.clearAll(for: [connectionId], removingSetAsideCopies: removingSetAside)
            }
            show(read.listed)
            keepsDamagedHistoryCopy = read.keepsDamagedCopy
        }
    }

    @concurrent
    nonisolated private static func changeHistory(
        for connectionId: UUID,
        in storage: QueryHistoryStorage,
        _ change: @Sendable (QueryHistoryStorage) -> Void
    ) async -> (listed: QueryHistoryStorage.Listed, keepsDamagedCopy: Bool) {
        change(storage)
        return (storage.listed(for: connectionId), storage.hasSetAsideCopies)
    }

    func navigateToPendingTable() {
        guard let table = TableSelectionResolver.resolve(pendingName: pendingTableName, in: tables) else { return }
        pendingTableName = nil
        selectedTab = .tables
        selectedTable = table
    }
}
