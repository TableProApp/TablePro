import Foundation
import Observation
import os
import TableProDatabase

@MainActor @Observable
final class SessionTransactionMonitor {
    nonisolated enum Hold: Sendable, Equatable {
        case open
        case aborted
    }

    // What a confirmation was opened for: a session, and the work it had seen. Work since then makes it stale.
    struct HoldToken {
        let driver: any DatabaseDriver
        let workGeneration: Int
    }

    private struct Entry {
        let driver: any DatabaseDriver
        var hold: Hold
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SessionTransactionMonitor")

    private var entries: [UUID: Entry] = [:]
    // Sessions whose last answer was idle, apart from those that could not say.
    @ObservationIgnored private var idleDrivers: [UUID: ObjectIdentifier] = [:]
    private var workCounts: [UUID: Int] = [:]
    @ObservationIgnored private var statementCounts: [UUID: Int] = [:]
    private var rollBackCounts: [UUID: Int] = [:]
    @ObservationIgnored private var refreshGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var workGenerations: [UUID: Int] = [:]
    @ObservationIgnored private let liveDriver: (UUID) -> (any DatabaseDriver)?

    init(liveDriver: @escaping (UUID) -> (any DatabaseDriver)?) {
        self.liveDriver = liveDriver
    }

    func hold(for connectionId: UUID) -> Hold? {
        entries[connectionId]?.hold
    }

    // A window still on a session another window replaced must not show, or act on, the newer session's transaction.
    func hold(for connectionId: UUID, on driver: (any DatabaseDriver)?) -> Hold? {
        guard let driver, let entry = entries[connectionId], entry.driver === driver else { return nil }
        return entry.hold
    }

    func token(for connectionId: UUID, on driver: (any DatabaseDriver)?) -> HoldToken? {
        guard let driver, hold(for: connectionId, on: driver) != nil else { return nil }
        return HoldToken(driver: driver, workGeneration: workGenerations[connectionId, default: 0])
    }

    func isKnownIdle(_ connectionId: UUID, on driver: (any DatabaseDriver)?) -> Bool {
        guard let driver else { return false }
        return idleDrivers[connectionId] == ObjectIdentifier(driver)
    }

    func rollBackCount(for connectionId: UUID) -> Int {
        rollBackCounts[connectionId, default: 0]
    }

    func isBusy(_ connectionId: UUID) -> Bool {
        workCounts[connectionId, default: 0] > 0
    }

    // A grid page is a read the app built, so a session lost under it cannot have committed anything.
    func isRunningStatements(_ connectionId: UUID) -> Bool {
        statementCounts[connectionId, default: 0] > 0
    }

    // `reading` work keeps Commit and Roll Back off the session while it streams, and stales a dialog opened before it.
    func track<T>(_ connectionId: UUID, reading: Bool = false, _ work: () async throws -> T) async rethrows -> T {
        workCounts[connectionId, default: 0] += 1
        if !reading { statementCounts[connectionId, default: 0] += 1 }
        workGenerations[connectionId, default: 0] += 1
        do {
            let value = try await work()
            await refresh(connectionId)
            endWork(connectionId, reading: reading)
            return value
        } catch {
            await refresh(connectionId)
            endWork(connectionId, reading: reading)
            throw error
        }
    }

    func refresh(_ connectionId: UUID) async {
        guard let driver = liveDriver(connectionId) else {
            entries[connectionId] = nil
            return
        }
        let generation = refreshGenerations[connectionId, default: 0] + 1
        refreshGenerations[connectionId] = generation
        let state = await driver.sessionTransactionState()
        // A newer read, or a session that replaced this driver while it answered, owns the entry now.
        guard refreshGenerations[connectionId] == generation, liveDriver(connectionId) === driver else { return }
        apply(state, from: driver, to: connectionId)
    }

    func commit(_ connectionId: UUID, as token: HoldToken) async throws {
        let driver = try actionDriver(for: connectionId, token: token)
        try await track(connectionId) {
            let generation = workGenerations[connectionId, default: 0]
            let state = await driver.sessionTransactionState()
            guard liveDriver(connectionId) === driver else { throw TransactionActionError.sessionReplaced }
            // Work another window ran during the read may have ended this transaction and opened another.
            guard workGenerations[connectionId, default: 0] == generation else {
                throw TransactionActionError.transactionChanged
            }
            if state == .abortedTransaction {
                entries[connectionId] = Entry(driver: driver, hold: .aborted)
                throw TransactionActionError.cannotCommit
            }
            try await driver.commitTransaction()
        }
    }

    func rollBack(_ connectionId: UUID, as token: HoldToken) async throws {
        let driver = try actionDriver(for: connectionId, token: token)
        try await track(connectionId) {
            try await driver.rollbackTransaction()
            rollBackCounts[connectionId, default: 0] += 1
        }
    }

    // Rows a view read inside a transaction its session lost are as stale as after a Roll Back.
    func transactionLost(_ connectionId: UUID) {
        rollBackCounts[connectionId, default: 0] += 1
    }

    func sessionEnded(_ connectionId: UUID, driver: any DatabaseDriver) {
        guard let entry = entries[connectionId], entry.driver === driver else { return }
        entries[connectionId] = nil
    }

    private func actionDriver(for connectionId: UUID, token: HoldToken) throws -> any DatabaseDriver {
        let live = liveDriver(connectionId)
        guard let live, live === token.driver, let entry = entries[connectionId], entry.driver === live else {
            if let entry = entries[connectionId], entry.driver !== live {
                entries[connectionId] = nil
            }
            Self.logger.info("Refused a transaction action: the session that held it is gone")
            throw TransactionActionError.sessionReplaced
        }
        guard workGenerations[connectionId, default: 0] == token.workGeneration else {
            Self.logger.info("Refused a transaction action: other work ran on the session before it was confirmed")
            throw TransactionActionError.transactionChanged
        }
        return live
    }

    private func apply(_ state: DriverTransactionState, from driver: any DatabaseDriver, to connectionId: UUID) {
        idleDrivers[connectionId] = state == .idle ? ObjectIdentifier(driver) : nil
        switch state {
        case .explicitTransaction, .implicitTransaction:
            entries[connectionId] = Entry(driver: driver, hold: .open)
        case .abortedTransaction:
            entries[connectionId] = Entry(driver: driver, hold: .aborted)
        case .idle:
            entries[connectionId] = nil
        case .unknown:
            if let entry = entries[connectionId], entry.driver !== driver {
                entries[connectionId] = nil
            }
        }
    }

    // A read cannot end a transaction, so only its start, which a confirmation may race, stales a dialog.
    private func endWork(_ connectionId: UUID, reading: Bool) {
        if !reading { workGenerations[connectionId, default: 0] += 1 }
        let remaining = workCounts[connectionId, default: 1] - 1
        workCounts[connectionId] = remaining > 0 ? remaining : nil
        guard !reading else { return }
        let statements = statementCounts[connectionId, default: 1] - 1
        statementCounts[connectionId] = statements > 0 ? statements : nil
    }
}

nonisolated enum TransactionActionError: Error, LocalizedError, Equatable {
    case cannotCommit
    case sessionReplaced
    case transactionChanged

    var errorDescription: String? {
        switch self {
        case .cannotCommit:
            String(localized: "The transaction on this connection can no longer be committed. Roll it back.")
        case .sessionReplaced:
            String(localized: "The session that held this transaction has ended.")
        case .transactionChanged:
            String(localized: "Other work ran on this connection before you confirmed. Check the transaction and try again.")
        }
    }
}
