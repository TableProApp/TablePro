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

    // What a session held when it ended. `duringWork`: a statement was running, so it may have ended the transaction.
    nonisolated struct EndedHold: Sendable, Equatable {
        let hold: Hold
        let duringWork: Bool
    }

    private struct Entry {
        let driver: any DatabaseDriver
        var hold: Hold
    }

    private struct EndedEntry {
        let driver: any DatabaseDriver
        let ended: EndedHold
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SessionTransactionMonitor")

    private var entries: [UUID: Entry] = [:]
    // Kept for a window still on the ended session, which says the transaction is gone once it redials.
    @ObservationIgnored private var endedEntries: [UUID: EndedEntry] = [:]
    // Sessions whose last answer was idle, apart from those that could not say.
    @ObservationIgnored private var idleDrivers: [UUID: ObjectIdentifier] = [:]
    private var workCounts: [UUID: Int] = [:]
    // Sessions an import holds: every other statement on them is refused until it ends.
    private var heldByImport: Set<UUID> = []
    @ObservationIgnored private var importEndHandlers: [UUID: [@MainActor () -> Void]] = [:]
    @ObservationIgnored private var statementCounts: [UUID: Int] = [:]
    private var rollBackCounts: [UUID: Int] = [:]
    @ObservationIgnored private var refreshGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var workGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var statementWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
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

    func endedHold(for connectionId: UUID, on driver: (any DatabaseDriver)?) -> EndedHold? {
        guard let driver, let entry = endedEntries[connectionId], entry.driver === driver else { return nil }
        return entry.ended
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

    func isHeldByImport(_ connectionId: UUID) -> Bool {
        heldByImport.contains(connectionId)
    }

    // Runs `handler` once the import holding the connection ends, or at once when none holds it.
    func afterImport(_ connectionId: UUID, _ handler: @escaping @MainActor () -> Void) {
        guard heldByImport.contains(connectionId) else {
            handler()
            return
        }
        importEndHandlers[connectionId, default: []].append(handler)
    }

    // A grid page is a read the app built, so a session lost under it cannot have committed anything.
    func isRunningStatements(_ connectionId: UUID) -> Bool {
        statementCounts[connectionId, default: 0] > 0
    }

    // A run that moves the session's database lets a write already on its way finish where it was aimed. Stop ends the
    // wait, as it ends a run queued behind another.
    func statementsFinished(for connectionId: UUID) async {
        guard isRunningStatements(connectionId) else { return }
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                statementWaiters[connectionId, default: [:]][waiter] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.statementWaiters[connectionId]?.removeValue(forKey: waiter)?.resume()
            }
        }
    }

    // `reading` work keeps Commit and Roll Back off the session while it streams, and stales a dialog opened before it.
    // Admission is decided before the first suspension, so nothing can slip in between the check and the mark, and
    // nothing ever waits: an import (`importing`) is refused while any other work runs on the session or the session
    // is moving (`sessionMoving`: a switch, a `USE`, a dial or a check), and every other statement, reads included, is
    // refused while an import holds it. A read inside an import's transaction is not harmless: a cancelled or failed
    // one aborts a PostgreSQL transaction, and an interrupt rolls back SQLite's.
    func track<T>(
        _ connectionId: UUID,
        reading: Bool = false,
        importing: Bool = false,
        sessionMoving: Bool = false,
        _ work: () async throws -> T
    ) async throws -> T {
        if heldByImport.contains(connectionId) { throw SessionHeldByImport() }
        if importing {
            if workCounts[connectionId, default: 0] > 0 || sessionMoving { throw SessionBusyForImport() }
            heldByImport.insert(connectionId)
        }
        workCounts[connectionId, default: 0] += 1
        if !reading { statementCounts[connectionId, default: 0] += 1 }
        workGenerations[connectionId, default: 0] += 1
        do {
            let value = try await work()
            await refresh(connectionId)
            endWork(connectionId, reading: reading, importing: importing)
            return value
        } catch {
            await refresh(connectionId)
            endWork(connectionId, reading: reading, importing: importing)
            throw error
        }
    }

    func refresh(_ connectionId: UUID) async {
        guard let driver = liveDriver(connectionId) else {
            retireEntry(connectionId)
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

    // A typed ROLLBACK or a lost session ends the transaction as the bar's Roll Back does, so views reload the same way.
    func noteRolledBack(_ connectionId: UUID) {
        rollBackCounts[connectionId, default: 0] += 1
    }

    func sessionEnded(_ connectionId: UUID, driver: any DatabaseDriver) {
        guard let entry = entries[connectionId], entry.driver === driver else { return }
        retireEntry(connectionId)
    }

    // Only for a session that is gone: its entry's driver can never be live again.
    private func retireEntry(_ connectionId: UUID) {
        guard let entry = entries.removeValue(forKey: connectionId) else { return }
        endedEntries[connectionId] = EndedEntry(
            driver: entry.driver,
            ended: EndedHold(hold: entry.hold, duringWork: isRunningStatements(connectionId))
        )
    }

    private func actionDriver(for connectionId: UUID, token: HoldToken) throws -> any DatabaseDriver {
        let live = liveDriver(connectionId)
        guard let live, live === token.driver, let entry = entries[connectionId], entry.driver === live else {
            if live == nil {
                retireEntry(connectionId)
            } else if let entry = entries[connectionId], entry.driver !== live {
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
        // A live session answered, so the window that redialed it has already read what the ended one held.
        endedEntries[connectionId] = nil
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
    private func endWork(_ connectionId: UUID, reading: Bool, importing: Bool) {
        if !reading { workGenerations[connectionId, default: 0] += 1 }
        let remaining = workCounts[connectionId, default: 1] - 1
        workCounts[connectionId] = remaining > 0 ? remaining : nil
        if importing {
            heldByImport.remove(connectionId)
            for handler in importEndHandlers.removeValue(forKey: connectionId) ?? [] {
                handler()
            }
        }
        guard !reading else { return }
        let statements = statementCounts[connectionId, default: 1] - 1
        statementCounts[connectionId] = statements > 0 ? statements : nil
        guard statements <= 0 else { return }
        for waiter in (statementWaiters.removeValue(forKey: connectionId) ?? [:]).values {
            waiter.resume()
        }
    }
}

// Any statement on a session an import holds, reads included, from any window.
nonisolated struct SessionHeldByImport: Error, LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "An import is running on this connection.")
    }

    var appError: AppError {
        AppError(
            category: .query,
            title: String(localized: "Import Running"),
            message: errorDescription ?? "",
            recovery: String(localized: "Try again once it ends."),
            underlying: self
        )
    }
}

// An import asked for a session that other work is using or moving; it starts only on one nothing else touches.
nonisolated struct SessionBusyForImport: Error, LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "Other work is running on this connection. Start the import again once it ends.")
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
