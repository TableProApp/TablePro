import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

@MainActor
private final class LiveSessions {
    var drivers: [UUID: any DatabaseDriver] = [:]
}

@MainActor
@Suite("Session transaction monitor", .timeLimit(.minutes(1)))
struct SessionTransactionMonitorTests {
    private let id = UUID()
    private let live: LiveSessions
    private let monitor: SessionTransactionMonitor

    init() {
        let live = LiveSessions()
        self.live = live
        monitor = SessionTransactionMonitor { live.drivers[$0] }
    }

    @discardableResult
    private func attach(_ state: DriverTransactionState = .idle) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = state
        live.drivers[id] = driver
        return driver
    }

    @Test("A run that leaves a transaction open shows it, explicit or implicit")
    func runLeavesTheTransactionOpen() async {
        let driver = attach(.explicitTransaction)
        await monitor.track(id) {}
        #expect(monitor.hold(for: id) == .open)

        driver.scriptedTransactionState = .implicitTransaction
        await monitor.track(id) {}
        #expect(monitor.hold(for: id) == .open)
    }

    @Test("A typed COMMIT clears it on the next settle")
    func typedCommitClears() async {
        let driver = attach(.explicitTransaction)
        await monitor.track(id) {}

        driver.scriptedTransactionState = .idle
        await monitor.track(id) {}

        #expect(monitor.hold(for: id) == nil)
    }

    @Test("Work that throws still refreshes")
    func throwingWorkRefreshes() async {
        attach(.abortedTransaction)

        await #expect(throws: MockDatabaseDriver.MockError.self) {
            try await monitor.track(id) { throw MockDatabaseDriver.MockError.scripted }
        }

        #expect(monitor.hold(for: id) == .aborted)
    }

    @Test("Commit and Roll Back run on the live driver and clear the indicator")
    func commitAndRollBackHitTheLiveDriver() async throws {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)
        driver.scriptedTransactionStates = [.explicitTransaction, .idle]

        try await monitor.commit(id, as: #require(monitor.token(for: id, on: driver)))

        #expect(driver.didCommitTransaction)
        #expect(monitor.hold(for: id) == nil)

        driver.scriptedTransactionState = .explicitTransaction
        await monitor.refresh(id)
        driver.scriptedTransactionState = .idle

        try await monitor.rollBack(id, as: #require(monitor.token(for: id, on: driver)))

        #expect(driver.didRollbackTransaction)
        #expect(monitor.hold(for: id) == nil)
    }

    @Test("An aborted transaction refuses Commit without sending it and still rolls back")
    func abortedRefusesCommit() async throws {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)
        driver.scriptedTransactionState = .abortedTransaction
        let commitToken = try #require(monitor.token(for: id, on: driver))

        await #expect(throws: TransactionActionError.cannotCommit) {
            try await monitor.commit(id, as: commitToken)
        }
        #expect(!driver.didCommitTransaction)
        #expect(monitor.hold(for: id) == .aborted)

        driver.scriptedTransactionStates = [.idle]
        try await monitor.rollBack(id, as: #require(monitor.token(for: id, on: driver)))

        #expect(driver.didRollbackTransaction)
        #expect(monitor.hold(for: id) == nil)
    }

    @Test("Commit on a session that replaced the one holding the transaction is refused and clears it")
    func replacedSessionRefusesCommit() async throws {
        let old = attach(.explicitTransaction)
        await monitor.refresh(id)
        let token = try #require(monitor.token(for: id, on: old))
        let replacement = attach(.idle)

        await #expect(throws: TransactionActionError.sessionReplaced) {
            try await monitor.commit(id, as: token)
        }

        #expect(!old.didCommitTransaction)
        #expect(!replacement.didCommitTransaction)
        #expect(monitor.hold(for: id) == nil)
    }

    @Test("A window on a replaced session sees no hold and cannot act on the newer session's transaction")
    func staleWindowCannotActOnTheNewerSession() async {
        let old = attach(.idle)
        let newer = attach(.explicitTransaction)
        await monitor.refresh(id)

        #expect(monitor.hold(for: id, on: old) == nil)
        #expect(monitor.token(for: id, on: old) == nil)
        #expect(monitor.hold(for: id, on: newer) == .open)
        await #expect(throws: TransactionActionError.sessionReplaced) {
            try await monitor.rollBack(id, as: SessionTransactionMonitor.HoldToken(driver: old, workGeneration: 0))
        }

        #expect(!newer.didRollbackTransaction)
        #expect(monitor.hold(for: id) == .open)
    }

    @Test("A confirmation goes stale once other work runs on the session")
    func workAfterTheTokenRefusesTheAction() async throws {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)
        let token = try #require(monitor.token(for: id, on: driver))

        await monitor.track(id) {}

        await #expect(throws: TransactionActionError.transactionChanged) {
            try await monitor.rollBack(id, as: token)
        }
        #expect(!driver.didRollbackTransaction)
        #expect(monitor.hold(for: id) == .open)
    }

    @Test("Work that runs while Commit reads the session's state refuses the Commit")
    func workDuringTheCommitReadRefusesIt() async throws {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)
        let token = try #require(monitor.token(for: id, on: driver))
        let gate = TestGate()
        driver.beforeTransactionState = { await gate.enter() }

        let commit = Task { try await monitor.commit(id, as: token) }
        await gate.waitUntilEntered()
        driver.beforeTransactionState = nil
        await monitor.track(id) {}
        await gate.open()

        await #expect(throws: TransactionActionError.transactionChanged) {
            try await commit.value
        }
        #expect(!driver.didCommitTransaction)
    }

    @Test("Only a Roll Back that went through counts")
    func rollBackCountsOnlySuccess() async throws {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)
        driver.rollbackError = MockDatabaseDriver.MockError.scripted

        let failing = try #require(monitor.token(for: id, on: driver))
        await #expect(throws: MockDatabaseDriver.MockError.self) {
            try await monitor.rollBack(id, as: failing)
        }
        #expect(monitor.rollBackCount(for: id) == 0)

        driver.rollbackError = nil
        let token = try #require(monitor.token(for: id, on: driver))
        driver.scriptedTransactionState = .idle
        try await monitor.rollBack(id, as: token)

        #expect(monitor.rollBackCount(for: id) == 1)
    }

    @Test("A late answer from a driver that was replaced while it answered is dropped")
    func lateAnswerFromReplacedDriverIsDropped() async {
        let gate = TestGate()
        let old = attach(.explicitTransaction)
        old.beforeTransactionState = { await gate.enter() }

        let pending = Task { await monitor.refresh(id) }
        await gate.waitUntilEntered()
        attach(.unknown)
        await gate.open()
        await pending.value

        #expect(monitor.hold(for: id) == nil)
    }

    @Test("A session's end clears only the entry its own driver holds")
    func sessionEndClearsOnlyItsDriver() async {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)

        monitor.sessionEnded(id, driver: MockDatabaseDriver())
        #expect(monitor.hold(for: id) == .open)

        monitor.sessionEnded(id, driver: driver)
        #expect(monitor.hold(for: id) == nil)
    }

    @Test("An unknown answer keeps what the session last reported")
    func unknownKeepsTheEntry() async {
        let driver = attach(.explicitTransaction)
        await monitor.refresh(id)

        driver.scriptedTransactionState = .unknown
        await monitor.refresh(id)

        #expect(monitor.hold(for: id) == .open)
    }

    @Test("The connection is busy while tracked work runs, and free once it settles")
    func busyDuringTrack() async {
        attach()
        let gate = TestGate()

        let work = Task { await monitor.track(id) { await gate.enter() } }
        await gate.waitUntilEntered()
        #expect(monitor.isBusy(id))

        await gate.open()
        await work.value
        #expect(!monitor.isBusy(id))
    }

    @Test("A real SQLite session shows BEGIN as open and Commit clears it")
    func sqliteBeginThenCommit() async throws {
        let driver = SQLiteDriver(source: .inMemory)
        try await driver.connect()
        live.drivers[id] = driver

        _ = try await monitor.track(id) { try await driver.execute(query: "BEGIN") }
        let afterBegin = monitor.hold(for: id)
        try await monitor.commit(id, as: #require(monitor.token(for: id, on: driver)))
        let afterCommit = monitor.hold(for: id)
        let serverState = await driver.sessionTransactionState()
        try await driver.disconnect()

        #expect(afterBegin == .open)
        #expect(afterCommit == nil)
        #expect(serverState == .idle)
    }
}
