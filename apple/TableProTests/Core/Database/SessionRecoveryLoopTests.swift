import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import TableProSQLGrammar
import TableProSSHConfig
import TableProTestSupport
import Testing

@MainActor
struct SessionRecoveryLoopTests {
    @MainActor
    fileprivate struct Fixture {
        let manager: DatabaseManager
        let clock: ManualClock
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver

        var id: UUID { connection.id }
        var session: ConnectionSession? { manager.session(for: connection.id) }
    }

    private static let stoppedResponding = "The connection stopped responding."
    private static let refused = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ECONNREFUSED),
        userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
    )
    private static let certificateError = SSLHandshakeError.untrustedCertificate(
        serverMessage: "self-signed certificate in certificate chain"
    )

    fileprivate func makeFixture(
        storage: ConnectionStorage = .shared,
        configure: (inout DatabaseConnection) -> Void = { _ in }
    ) -> Fixture {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let clock = ManualClock()
        let manager = DatabaseManager(connectionStorage: storage, recoveryClock: clock)
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        configure(&connection)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "app"
        manager.injectSession(session, for: connection.id)
        FakeMSSQLPlugin.recordConfigurations(for: connection.id)
        return Fixture(manager: manager, clock: clock, connection: connection, driver: driver)
    }

    fileprivate func cleanUp(_ fixture: Fixture) async {
        fixture.manager.endRecoveryLoop(for: fixture.id)
        await fixture.manager.stopHealthMonitor(for: fixture.id)
        fixture.manager.removeSession(for: fixture.id)
        FakeMSSQLPlugin.clearConnectFailure(for: fixture.id)
        FakeMSSQLPlugin.clearConnectHold(for: fixture.id)
        FakeMSSQLPlugin.clearConfigurations(for: fixture.id)
        await SchemaService.shared.invalidate(connectionId: fixture.id)
    }

    private func makeProxiedFixture(through server: FakeSOCKS5Server) -> Fixture {
        makeFixture { connection in
            // Network.framework never proxies a loopback target, so localhost would dial the Mac's own port.
            connection.host = "db.internal.example"
            connection.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "127.0.0.1", port: server.port))
        }
    }

    private func cleanUpProxied(_ fixture: Fixture, server: FakeSOCKS5Server) async {
        try? await SOCKSProxyManager.shared.closeTunnel(connectionId: fixture.id)
        server.stop()
        await cleanUp(fixture)
    }

    fileprivate func loopTask(_ fixture: Fixture) throws -> Task<Void, Never> {
        try #require(fixture.manager.recoveryLoops[fixture.id]?.task)
    }

    fileprivate func runNextAttempt(_ fixture: Fixture) async {
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: .seconds(DatabaseManager.maxRecoveryDelay))
    }

    private func runEveryAttempt(_ fixture: Fixture) async {
        for _ in 1...ConnectionRecoveryProgress.maxAttempts {
            await runNextAttempt(fixture)
        }
    }

    @Test("A dropped tunnel keeps the driver and the data while the loop redials")
    func dropKeepsTheDriverAndData() async {
        let fixture = makeFixture()

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)

        let session = fixture.session
        #expect(session?.driver === fixture.driver)
        #expect(session?.browseDatabase == "app")
        #expect(session?.status == .connected)
        #expect(session?.liveness == .recovering)
        #expect(session?.recovery == ConnectionRecoveryProgress(attempt: 1, cause: "SSH tunnel disconnected."))
        #expect(fixture.manager.disconnectReason(for: fixture.id) == nil)
        #expect(fixture.manager.recoveryLoops[fixture.id] != nil)
        await cleanUp(fixture)
    }

    @Test(
        "Every transport drop names its transport and offers no click",
        arguments: ConnectionTunnelKind.allCases.filter { $0 != .remoteFile }
    )
    func everyDropNamesItsTransport(kind: ConnectionTunnelKind) async {
        let fixture = makeFixture()
        let manager = fixture.manager

        switch kind {
        case .ssh: await manager.handleSSHTunnelDied(connectionId: fixture.id)
        case .cloudflare: await manager.handleCloudflareTunnelDied(connectionId: fixture.id)
        case .cloudSQLProxy: await manager.handleCloudSQLProxyTunnelDied(connectionId: fixture.id)
        case .socksProxy: await manager.handleSOCKSProxyTunnelDied(connectionId: fixture.id)
        case .tunnelCommand: await manager.handleTunnelCommandDied(connectionId: fixture.id)
        case .remoteDatabaseSession: await manager.handleRemoteSQLiteTunnelDied(connectionId: fixture.id)
        case .remoteFile: break
        }

        let cause = fixture.session?.recovery?.cause ?? ""
        #expect(!cause.isEmpty)
        #expect(!cause.localizedCaseInsensitiveContains("click"))
        #expect(fixture.session?.driver === fixture.driver)
        await cleanUp(fixture)
    }

    @Test("A second drop while one loop runs starts no other")
    func oneLoopPerSession() async {
        let fixture = makeFixture()

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)
        let first = fixture.manager.recoveryLoops[fixture.id]?.token
        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)

        #expect(first != nil)
        #expect(fixture.manager.recoveryLoops[fixture.id]?.token == first)
        #expect(fixture.session?.recovery?.cause == "SSH tunnel disconnected.")
        await cleanUp(fixture)
    }

    @Test("A lost session waits for the user instead of redialing on its own")
    func lostSessionStartsNoLoop() async {
        let fixture = makeFixture()
        let lost = ConnectionFailureInfo(message: "gone")
        fixture.manager.markSessionUnreachable(fixture.id, startedWith: fixture.driver, info: lost)

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)

        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(fixture.session?.liveness == .unreachable(lost))
        await cleanUp(fixture)
    }

    @Test("Each failed attempt advances the progress and keeps the session believable")
    func attemptsAdvanceTheProgress() async {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        #expect(fixture.session?.recovery == ConnectionRecoveryProgress(attempt: 1, cause: Self.stoppedResponding))

        await runNextAttempt(fixture)
        await fixture.clock.waitUntilSleeping()

        #expect(fixture.session?.recovery == ConnectionRecoveryProgress(attempt: 2, cause: Self.stoppedResponding))
        #expect(fixture.session?.liveness == .recovering)
        #expect(fixture.session?.driver === fixture.driver)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == 1)
        await cleanUp(fixture)
    }

    @Test("A failed attempt's reason becomes the cause the next attempt shows")
    func failureReasonBecomesTheCause() async {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.certificateError)
        let reason = ConnectionFailureClassifier.info(for: Self.certificateError)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        await runNextAttempt(fixture)
        await fixture.clock.waitUntilSleeping()

        #expect(fixture.session?.recovery == ConnectionRecoveryProgress(attempt: 2, cause: reason.message))
        #expect(fixture.manager.disconnectReason(for: fixture.id) == nil)
        await cleanUp(fixture)
    }

    @Test("Ten failed attempts mark the session lost with the cause and keep the driver")
    func exhaustedRecoveryMarksTheSessionLost() async throws {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runEveryAttempt(fixture)
        await loop.value

        let expected = DatabaseManager.exhaustedRecoveryInfo(
            cause: .stoppedResponding,
            lastFailure: nil,
            attempts: ConnectionRecoveryProgress.maxAttempts
        )
        #expect(expected.message == Self.stoppedResponding)
        #expect(expected.failureReason == "Reconnecting failed after 10 attempts.")
        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.recovery == nil)
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.manager.disconnectReason(for: fixture.id) == .sessionLost(expected))
        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == ConnectionRecoveryProgress.maxAttempts)
        #expect(fixture.clock.pendingSleeperCount == 0)
        await cleanUp(fixture)
    }

    @Test("An exhausted recovery names the last attempt's own reason")
    func exhaustedRecoveryNamesTheLastFailure() async throws {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.certificateError)
        let reason = ConnectionFailureClassifier.info(for: Self.certificateError)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runEveryAttempt(fixture)
        await loop.value

        guard case .unreachable(let info?) = fixture.session?.liveness else {
            Issue.record("an exhausted recovery should mark the session lost")
            await cleanUp(fixture)
            return
        }
        #expect(info.message == reason.message)
        #expect(info.failureReason == "Reconnecting failed after 10 attempts.")
        await cleanUp(fixture)
    }

    @Test("A later attempt that fails for an ordinary reason drops the earlier certificate reason")
    func laterOrdinaryFailureReplacesTheReason() async throws {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.certificateError)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await fixture.clock.waitUntilSleeping()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)
        for _ in 2...ConnectionRecoveryProgress.maxAttempts {
            await runNextAttempt(fixture)
        }
        await loop.value

        guard case .unreachable(let info?) = fixture.session?.liveness else {
            Issue.record("an exhausted recovery should mark the session lost")
            await cleanUp(fixture)
            return
        }
        #expect(info.message == Self.stoppedResponding)
        await cleanUp(fixture)
    }

    @Test("A TLS failure only a settings change can fix ends the loop at once and says why")
    func configurationFailureEndsTheLoop() async throws {
        let fixture = makeFixture()
        let error = SSLHandshakeError.clientCertRequired(serverMessage: "certificate required")
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: error)
        let expected = ConnectionFailureClassifier.info(for: error)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await loop.value

        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.recovery == nil)
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == 1)
        await cleanUp(fixture)
    }

    @Test("A recovery that reconnects goes live and clears its progress")
    func successfulAttemptGoesLive() async throws {
        let fixture = makeFixture()

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await loop.value

        #expect(fixture.session?.driver !== fixture.driver)
        #expect(fixture.session?.driver != nil)
        #expect(fixture.session?.liveness == .live)
        #expect(fixture.session?.recovery == nil)
        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        await cleanUp(fixture)
    }

    @Test("A recovery that replaces a driver holding a transaction refuses the next statement once")
    func recoveryReportsTheTransactionItEnded() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        let scope = DatabaseScope(connectionId: fixture.id, database: "app", schema: nil)
        fixture.driver.sessionTransactionStateToReturn = .inTransaction
        try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { _ in () }
        #expect(manager.sessionTransactions.holdsTransaction(connectionId: fixture.id, container: "app"))

        manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await loop.value

        #expect(fixture.session?.driver !== fixture.driver)
        #expect(!manager.sessionTransactions.holdsTransaction(connectionId: fixture.id, container: "app"))
        #expect(manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { _ in () }
        }
        #expect(error?.localizedDescription.contains(DatabaseManager.parkedTransactionLostMessage(database: "app")) == true)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        await cleanUp(fixture)
    }

    @Test("A recovery that replaces an idle driver refuses nothing")
    func recoveryOfAnIdleDriverReportsNothing() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        let scope = DatabaseScope(connectionId: fixture.id, database: "app", schema: nil)
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { _ in () }

        manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await loop.value

        #expect(fixture.session?.driver !== fixture.driver)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        await cleanUp(fixture)
    }

    // Inside the user's own lease, as a query tab notes what it runs.
    private func runUserStatements(_ statements: [String], on fixture: Fixture) async throws {
        let manager = fixture.manager
        let scope = DatabaseScope(connectionId: fixture.id, database: "app", schema: nil)
        try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .untracked) { driver in
            await manager.noteSessionStatements(statements, ranOn: driver, scope: scope)
        }
    }

    private func recover(_ fixture: Fixture) async throws {
        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await loop.value
    }

    private func runNextStatement(_ fixture: Fixture, ownsSessionState: Bool = true) async throws {
        let scope = DatabaseScope(connectionId: fixture.id, database: "app", schema: nil)
        try await fixture.manager.withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .untracked, ownsSessionState: ownsSessionState
        ) { _ in () }
    }

    private func nextStatementRefusal(_ fixture: Fixture) async -> DatabaseError? {
        do {
            try await runNextStatement(fixture)
            return nil
        } catch {
            return error as? DatabaseError
        }
    }

    @Test("A recovery that replaces a driver whose session set something up refuses the next statement once")
    func recoveryReportsTheSessionStateItEnded() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(["CREATE TABLE #orders (id int)"], on: fixture)
        #expect(manager.sessionStateLedger.state(heldBy: fixture.driver, for: fixture.id) == .temporaryObjects)

        try await recover(fixture)

        #expect(fixture.session?.driver !== fixture.driver)
        let refusal = await nextStatementRefusal(fixture)
        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .temporaryObjects)
        )
        #expect(refusal?.localizedDescription.contains(expected) == true)
        try await runNextStatement(fixture)
        await cleanUp(fixture)
    }

    @Test("A recovery that ends a transaction and what the session set up names both in one message")
    func recoveryReportsTransactionAndStateInOneMessage() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .inTransaction
        try await runUserStatements(["SET XACT_ABORT ON"], on: fixture)
        #expect(manager.sessionTransactions.holdsTransaction(connectionId: fixture.id, container: "app"))

        try await recover(fixture)

        let refusal = await nextStatementRefusal(fixture)
        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: true, state: .sessionSettings)
        )
        #expect(refusal?.localizedDescription.contains(expected) == true)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        await cleanUp(fixture)
    }

    // A grid save, an Explain or an MCP statement takes the report as the user's statement would, as a lost
    // transaction's report always went.
    @Test("The first turn that owns the session after the loss is refused once, whatever work it is, and the next runs")
    func firstOwningTurnTakesTheStateReport() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(["CREATE TABLE #orders (id int)"], on: fixture)

        try await recover(fixture)

        let scope = DatabaseScope(connectionId: fixture.id, database: "app", schema: nil)
        let error = await #expect(throws: DatabaseError.self) {
            try await manager.withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .protectedWrite) { _ in () }
        }
        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .temporaryObjects)
        )
        #expect(error?.localizedDescription.contains(expected) == true)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        try await runNextStatement(fixture)
        await cleanUp(fixture)
    }

    @Test("A reconnect the user asks for reports a lane's lost transaction but not what its session set up")
    func manualReconnectReportsNoSessionState() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        let logs = MockDatabaseDriver(connection: fixture.connection)
        logs.sessionTransactionStateToReturn = .idle
        let audit = MockDatabaseDriver(connection: fixture.connection)
        audit.sessionTransactionStateToReturn = .inTransaction
        manager.sessionLanes.park(logs, database: "logs", for: fixture.id)
        manager.sessionLanes.park(audit, database: "audit", for: fixture.id)
        let logsLane = SessionTransactionTracker.Key(connectionId: fixture.id, lane: "logs")
        let auditLane = SessionTransactionTracker.Key(connectionId: fixture.id, lane: "audit")
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .temporaryObjects), on: logs, for: logsLane)
        manager.sessionStateLedger.record(SQLSessionStateEffect(creates: .sessionSettings), on: audit, for: auditLane)
        // A session that stopped answering moves the pooled transport, as a rebuilt tunnel does.
        manager.updateSession(fixture.id) { $0.liveness = .unreachable(nil) }

        try? await manager.reconnectSession(fixture.id)

        #expect(logs.disconnectCallCount == 1)
        #expect(audit.disconnectCallCount == 1)
        #expect(!manager.sessionLanes.hasLoss(database: "logs", for: fixture.id))
        #expect(
            manager.sessionLanes.takeLoss(database: "audit", for: fixture.id)
                == SessionLoss(transaction: true, state: [])
        )
        await cleanUp(fixture)
    }

    @Test("A recovery of a session whose statements set nothing up refuses nothing")
    func recoveryOfASessionThatSetNothingUpReportsNothing() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(["SELECT * FROM orders", "UPDATE orders SET total = 0 WHERE id = 1"], on: fixture)
        #expect(manager.sessionStateLedger.state(heldBy: fixture.driver, for: fixture.id).isEmpty)

        try await recover(fixture)

        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        try await runNextStatement(fixture)
        await cleanUp(fixture)
    }

    @Test("A startup command the user runs again is not reported, since the reconnect runs it too")
    func startupCommandRerunByTheUserIsNotReported() async throws {
        let fixture = makeFixture { $0.startupCommands = "SET NOCOUNT ON" }
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(["SET NOCOUNT ON;"], on: fixture)
        #expect(manager.sessionStateLedger.state(heldBy: fixture.driver, for: fixture.id).isEmpty)

        try await recover(fixture)

        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        try await runNextStatement(fixture)
        await cleanUp(fixture)
    }

    @Test("A metadata read on the session driver leaves the lost session state's report for the user's statement")
    func metadataReadLeavesTheStateReport() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(["DECLARE c CURSOR FOR SELECT 1"], on: fixture)

        try await recover(fixture)
        try await runNextStatement(fixture, ownsSessionState: false)

        #expect(manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        let refusal = await nextStatementRefusal(fixture)
        #expect(refusal != nil)
        #expect(!manager.sessionLanes.hasLoss(database: "app", for: fixture.id))
        await cleanUp(fixture)
    }

    @Test("The report names kinds only, never a statement, a name or a value it carried")
    func stateMessageNamesNoStatementText() async throws {
        let fixture = makeFixture()
        fixture.driver.sessionTransactionStateToReturn = .idle
        try await runUserStatements(
            ["SET app.key = 'secret'", "EXEC sp_set_session_context 'api_token', 'hunter2'"], on: fixture
        )

        try await recover(fixture)

        let refusal = await nextStatementRefusal(fixture)
        let message = refusal?.localizedDescription ?? ""
        let expected = DatabaseManager.sessionLostMessage(
            database: "app", loss: SessionLoss(transaction: false, state: .sessionSettings)
        )
        #expect(message.contains(expected))
        for leaked in ["secret", "app.key", "api_token", "hunter2", "sp_set_session_context"] {
            #expect(!message.contains(leaked))
        }
        await cleanUp(fixture)
    }

    @Test("Cancel during the backoff stops the loop before it dials and marks the session lost")
    func cancelDuringBackoffStopsTheLoop() async throws {
        let fixture = makeFixture()

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)
        let loop = try loopTask(fixture)
        await fixture.clock.waitUntilSleeping()
        fixture.manager.cancelRecovery(for: fixture.id)
        await loop.value

        let expected = DatabaseManager.cancelledRecoveryInfo(cause: "SSH tunnel disconnected.")
        #expect(expected.failureReason == "Reconnecting was cancelled.")
        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.recovery == nil)
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.manager.disconnectReason(for: fixture.id) == .sessionLost(expected))
        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)
        #expect(fixture.clock.pendingSleeperCount == 0)
        await cleanUp(fixture)
    }

    @Test("An attempt that finishes after Cancel does not bring the session back")
    func lateSuccessAfterCancelIsDiscarded() async throws {
        let fixture = makeFixture()
        let hold = FakeMSSQLPlugin.holdConnect(for: fixture.id)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await hold.waitUntilReached()
        fixture.manager.cancelRecovery(for: fixture.id)
        await hold.release()
        await loop.value

        let expected = DatabaseManager.cancelledRecoveryInfo(cause: Self.stoppedResponding)
        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.session?.recovery == nil)
        #expect(fixture.manager.healthMonitors[fixture.id] == nil)
        #expect(fixture.clock.pendingSleeperCount == 0)
        await cleanUp(fixture)
    }

    @Test("A reconnect the user asks for cancels the loop before it dials")
    func manualReconnectSupersedesTheLoop() async throws {
        let fixture = makeFixture()

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)
        let loop = try loopTask(fixture)
        await fixture.clock.waitUntilSleeping()

        try await fixture.manager.connectToSession(fixture.connection)
        await loop.value

        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(fixture.session?.driver !== fixture.driver)
        #expect(fixture.session?.liveness == .live)
        #expect(fixture.session?.recovery == nil)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == 1)
        #expect(fixture.clock.pendingSleeperCount == 0)
        await cleanUp(fixture)
    }

    @Test("A connect the app starts on its own leaves the loop in charge")
    func backgroundConnectLeavesTheLoopAlone() async {
        let fixture = makeFixture()

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)
        let token = fixture.manager.recoveryLoops[fixture.id]?.token
        await #expect(throws: (any Error).self) {
            try await fixture.manager.connectToSession(fixture.connection, trigger: .background)
        }

        #expect(token != nil)
        #expect(fixture.manager.recoveryLoops[fixture.id]?.token == token)
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.session?.recovery?.attempt == 1)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)
        await cleanUp(fixture)
    }

    @Test("A check before use that answers after Cancel does not bring the session back")
    func verificationAfterCancelDoesNotRevive() async throws {
        let fixture = makeFixture()
        let driver = fixture.driver
        let ping = AsyncGate()
        driver.pingGate = ping
        driver.pingError = DatabaseError.notConnected
        fixture.manager.markSessionVerified(fixture.id, at: .distantPast)

        let manager = fixture.manager
        let id = fixture.id
        let check = Task { @MainActor in await manager.verifyBeforeUse(id) }
        try await waitUntil { driver.pingCallCount == 1 }
        await manager.handleSSHTunnelDied(connectionId: id)
        manager.cancelRecovery(for: id)
        await ping.open()
        await check.value

        let expected = DatabaseManager.cancelledRecoveryInfo(cause: "SSH tunnel disconnected.")
        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.driver === fixture.driver)
        #expect(manager.recoveryLoops[id] == nil)
        #expect(FakeMSSQLPlugin.configurations(for: id).isEmpty)
        await cleanUp(fixture)
    }

    @Test("A check before use redials through the loop, and Cancel keeps its late success out")
    func verificationRedialIsTheLoopsAttempt() async throws {
        let fixture = makeFixture()
        fixture.driver.pingError = DatabaseError.notConnected
        fixture.manager.markSessionVerified(fixture.id, at: .distantPast)
        let hold = FakeMSSQLPlugin.holdConnect(for: fixture.id)

        let manager = fixture.manager
        let id = fixture.id
        let check = Task { @MainActor in await manager.verifyBeforeUse(id) }
        await hold.waitUntilReached()
        let loop = try loopTask(fixture)
        #expect(fixture.session?.recovery?.attempt == 1)
        manager.cancelRecovery(for: id)
        await hold.release()
        await check.value
        await loop.value

        let expected = DatabaseManager.cancelledRecoveryInfo(cause: Self.stoppedResponding)
        #expect(fixture.session?.liveness == .unreachable(expected))
        #expect(fixture.session?.driver === fixture.driver)
        #expect(fixture.session?.recovery == nil)
        #expect(FakeMSSQLPlugin.configurations(for: id).count == 1)
        await cleanUp(fixture)
    }

    @Test("A recovery superseded while it closes the database lanes leaves the newer tunnel open")
    func supersededDuringLaneTeardownKeepsTheNewTunnel() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        let fixture = makeProxiedFixture(through: server)
        let lane = MockDatabaseDriver(connection: fixture.connection)
        let teardown = AsyncGate()
        lane.sessionTransactionStateGate = teardown
        fixture.manager.sessionLanes.park(lane, database: "logs", for: fixture.id)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await teardown.arrived(1)

        try await fixture.manager.connectToSession(fixture.connection)
        let winningPort = await SOCKSProxyManager.shared.getLocalPort(connectionId: fixture.id)
        await teardown.open()
        await loop.value

        #expect(winningPort != nil)
        #expect(await SOCKSProxyManager.shared.hasTunnel(connectionId: fixture.id))
        #expect(await SOCKSProxyManager.shared.getLocalPort(connectionId: fixture.id) == winningPort)
        #expect(fixture.session?.liveness == .live)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == 1)
        await cleanUpProxied(fixture, server: server)
    }

    @Test("A failed attempt that cleans up after a manual reconnect leaves the new tunnel open")
    func lateFailureCleanupKeepsTheNewTunnel() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        let fixture = makeProxiedFixture(through: server)
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)
        let hold = FakeMSSQLPlugin.holdConnect(for: fixture.id)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runNextAttempt(fixture)
        await hold.waitUntilReached()
        let staleAttemptPort = await SOCKSProxyManager.shared.getLocalPort(connectionId: fixture.id)
        FakeMSSQLPlugin.clearConnectFailure(for: fixture.id)
        FakeMSSQLPlugin.clearConnectHold(for: fixture.id)

        try await fixture.manager.connectToSession(fixture.connection)
        let winningPort = await SOCKSProxyManager.shared.getLocalPort(connectionId: fixture.id)
        await hold.release()
        await loop.value

        #expect(staleAttemptPort != nil)
        #expect(winningPort != nil)
        #expect(await SOCKSProxyManager.shared.hasTunnel(connectionId: fixture.id))
        #expect(await SOCKSProxyManager.shared.getLocalPort(connectionId: fixture.id) == winningPort)
        #expect(fixture.session?.liveness == .live)
        await cleanUpProxied(fixture, server: server)
    }

    @Test("A dropped transport closes the lanes it carried and notes their open transactions")
    func dropClosesTheLanesItCarried() async {
        let fixture = makeFixture()
        let lane = MockDatabaseDriver(connection: fixture.connection)
        lane.sessionTransactionStateToReturn = .inTransaction
        fixture.manager.sessionLanes.park(lane, database: "logs", for: fixture.id)

        await fixture.manager.handleSSHTunnelDied(connectionId: fixture.id)
        await fixture.clock.waitUntilSleeping()

        #expect(fixture.manager.sessionLanes.parkedDriver(for: fixture.id, database: "logs") == nil)
        #expect(lane.disconnectCallCount == 1)
        #expect(fixture.manager.sessionLanes.hasLoss(database: "logs", for: fixture.id))
        #expect(fixture.session?.driver === fixture.driver)
        await cleanUp(fixture)
    }

    @Test("A loop superseded while a blocked ping holds the monitor's stop leaves the replacement's lanes alone")
    func supersededDuringMonitorStopKeepsTheReplacementLanes() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        let id = fixture.id
        let monitorClock = ManualClock()
        let ping = AsyncGate()
        let monitor = ConnectionHealthMonitor(
            connectionId: id,
            pingInterval: { .seconds(30) },
            pingHandler: {
                await ping.wait()
                return false
            },
            onPingFailed: { .handedOff },
            clock: monitorClock
        )
        manager.healthMonitors[id] = monitor
        await monitor.startMonitoring()
        for _ in 0 ..< 2 {
            await monitorClock.waitUntilSleeping()
            monitorClock.advance(by: .seconds(60))
        }
        await ping.arrived(1)

        await manager.handleSSHTunnelDied(connectionId: id)
        let loop = try loopTask(fixture)
        try await waitUntil { await MainActor.run { manager.healthMonitors[id] == nil } }

        try await manager.connectToSession(fixture.connection)
        let replacementLane = MockDatabaseDriver(connection: fixture.connection)
        replacementLane.sessionTransactionStateToReturn = .inTransaction
        manager.sessionLanes.park(replacementLane, database: "logs", for: id)
        await ping.open()
        await loop.value

        #expect(manager.sessionLanes.parkedDriver(for: id, database: "logs") === replacementLane)
        #expect(replacementLane.disconnectCallCount == 0)
        #expect(!manager.sessionLanes.hasLoss(database: "logs", for: id))
        #expect(fixture.session?.driver !== fixture.driver)
        #expect(fixture.session?.liveness == .live)
        await cleanUp(fixture)
    }

    @Test("An MCP or AppleScript status read reports connecting while the loop redials, then the failure")
    func externalStatusFollowsTheLoop() async throws {
        let fixture = makeFixture()
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)
        let bridge = DatabaseAccessBridge(manager: fixture.manager)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        #expect(try await bridge.connectionStatus(connectionId: fixture.id).status == .connecting)
        #expect(fixture.session?.reportedStatus == .connected)

        await runEveryAttempt(fixture)
        await loop.value

        #expect(try await bridge.connectionStatus(connectionId: fixture.id).status == .error(Self.stoppedResponding))
        await cleanUp(fixture)
    }

    @Test("The MCP status tool says connecting for a session the loop is redialing")
    func mcpStatusToolSaysConnecting() async throws {
        let connection = TestFixtures.makeConnection(name: "Prod")
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        DatabaseManager.shared.markSessionRecovering(
            connection.id,
            progress: ConnectionRecoveryProgress(attempt: 2, cause: nil)
        )

        let json = try await MCPConnectionBridge().getConnectionStatus(connectionId: connection.id)

        guard case .object(let fields) = json else {
            Issue.record("the status tool should answer with an object")
            return
        }
        #expect(fields["status"] == .string("connecting"))
    }

    @Test("An external connect after the loop gave up redials the session through the normal path")
    func externalConnectAfterExhaustionRedials() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-recovery-\(UUID().uuidString).json")
        let suite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
        defer {
            suite.defaults.removePersistentDomain(forName: suite.suiteName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        let fixture = makeFixture(storage: storage)
        storage.addConnection(fixture.connection)
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        let loop = try loopTask(fixture)
        await runEveryAttempt(fixture)
        await loop.value
        guard case .unreachable = fixture.session?.liveness else {
            Issue.record("the loop should have given up")
            await cleanUp(fixture)
            return
        }
        FakeMSSQLPlugin.clearConnectFailure(for: fixture.id)

        _ = try await DatabaseAccessBridge(manager: fixture.manager).connect(connectionId: fixture.id)

        #expect(fixture.session?.driver !== fixture.driver)
        #expect(fixture.session?.liveness == .live)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).count == ConnectionRecoveryProgress.maxAttempts + 1)
        await cleanUp(fixture)
    }

    @Test("A failed health check hands the session to the loop and retires the monitor")
    func failedHealthCheckStartsTheLoop() async {
        let fixture = makeFixture()
        fixture.manager.healthMonitors[fixture.id] = ConnectionHealthMonitor(
            connectionId: fixture.id,
            pingInterval: { nil },
            pingHandler: { false },
            onPingFailed: { .handedOff }
        )

        let handling = fixture.manager.healthCheckFailed(fixture.id)

        #expect(handling == .handedOff)
        #expect(fixture.manager.healthMonitors[fixture.id] == nil)
        #expect(fixture.session?.recovery == ConnectionRecoveryProgress(attempt: 1, cause: Self.stoppedResponding))
        #expect(fixture.session?.driver === fixture.driver)
        await cleanUp(fixture)
    }

    @Test("A failed check on a driver a database switch replaced leaves the session alone")
    func failedCheckOnAReplacedDriverIsIgnored() async {
        let fixture = makeFixture()
        fixture.manager.healthMonitors[fixture.id] = ConnectionHealthMonitor(
            connectionId: fixture.id,
            pingInterval: { nil },
            pingHandler: { false },
            onPingFailed: { .handedOff }
        )
        fixture.manager.notePinged(MockDatabaseDriver(connection: fixture.connection), for: fixture.id)

        let handling = fixture.manager.healthCheckFailed(fixture.id)

        #expect(handling == .ignored)
        #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
        #expect(fixture.session?.liveness == .live)
        await cleanUp(fixture)
    }

    @Test("Waking the Mac starts every dead tunnel's recovery at once")
    func wakeRecoversSessionsConcurrently() async throws {
        let clock = ManualClock()
        let manager = DatabaseManager(recoveryClock: clock)
        var ids: [UUID] = []
        for name in ["First", "Second"] {
            var connection = TestFixtures.makeConnection(name: name, type: .postgresql)
            connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "ssh.example.com"))
            var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
            session.status = .connected
            manager.injectSession(session, for: connection.id)
            ids.append(connection.id)
        }

        await manager.validateTunneledSessions()
        try await waitUntil { clock.pendingSleeperCount == ids.count }

        for id in ids {
            #expect(manager.session(for: id)?.liveness == .recovering)
            #expect(manager.session(for: id)?.recovery?.attempt == 1)
            manager.removeSession(for: id)
        }
        #expect(manager.recoveryLoops.isEmpty)
    }
}

extension GlobalStateSuites {
    // Writes the shared SSH profile store across suspensions.
    @MainActor
    struct SessionRecoveryMovedProfileTests {
        private let loop = SessionRecoveryLoopTests()

        private func movedProfileFixture() -> (SessionRecoveryLoopTests.Fixture, restore: () -> Void) {
            let profiles = SSHProfileStorage.shared
            let saved = profiles.loadProfiles()
            let moved = SSHProfile(name: "Jump", host: "bastion-b.example", port: 22, username: "ops", authMethod: .password)
            profiles.saveProfilesWithoutSync(saved + [moved])
            var dialed = moved.toSSHConfiguration()
            dialed.host = "bastion-a.example"
            let fixture = loop.makeFixture { connection in
                connection.sshTunnelMode = .profile(id: moved.id, snapshot: dialed)
                connection.sshConfig = dialed
            }
            return (fixture, { profiles.saveProfilesWithoutSync(saved) })
        }

        @Test("A recovery after the linked SSH profile moved to another server stops and dials nothing")
        func movedProfileEndsTheLoop() async throws {
            let (fixture, restore) = movedProfileFixture()
            defer { restore() }
            let expected = ConnectionFailureClassifier.info(for: ConnectionTunnelError.sshProfileMoved)

            fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
            let task = try loop.loopTask(fixture)
            await loop.runNextAttempt(fixture)
            await task.value

            #expect(fixture.session?.liveness == .unreachable(expected))
            #expect(fixture.session?.driver === fixture.driver)
            #expect(fixture.manager.recoveryLoops[fixture.id] == nil)
            #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)
            await loop.cleanUp(fixture)
        }

        @Test("A connect no window asked for keeps a dialed session off the moved profile", arguments: [
            ConnectTrigger.request, .background,
        ])
        func unattendedConnectKeepsTheDialedRoute(trigger: ConnectTrigger) async throws {
            let (fixture, restore) = movedProfileFixture()
            defer { restore() }
            var dialed = try #require(fixture.session)
            dialed.effectiveConnection = fixture.connection
            fixture.manager.injectSession(dialed, for: fixture.id)
            fixture.manager.markSessionUnreachable(fixture.id, startedWith: fixture.driver, info: nil)
            let expected = ConnectionFailureClassifier.info(for: ConnectionTunnelError.sshProfileMoved)

            for _ in 1...2 {
                await #expect(throws: ConnectionTunnelError.sshProfileMoved) {
                    try await fixture.manager.ensureConnected(fixture.connection, trigger: trigger)
                }
            }

            #expect(fixture.session?.liveness == .unreachable(expected))
            #expect(fixture.session?.driver === fixture.driver)
            #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)
            await loop.cleanUp(fixture)
        }

        @Test("A connect that failed and took the session with it still keeps the route until a disconnect")
        func failedConnectKeepsTheDialedRoute() async throws {
            let (fixture, restore) = movedProfileFixture()
            defer { restore() }
            fixture.manager.dialedConnections[fixture.id] = fixture.connection
            fixture.manager.removeSession(for: fixture.id)

            await #expect(throws: ConnectionTunnelError.sshProfileMoved) {
                try await fixture.manager.ensureConnected(fixture.connection)
            }
            #expect(fixture.session == nil)
            #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)

            await fixture.manager.disconnectSession(fixture.id)
            #expect(fixture.manager.dialedConnections[fixture.id] == nil)
            await loop.cleanUp(fixture)
        }
    }
}
