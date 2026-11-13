//
//  ImportSinkRun.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

internal final class ImportSinkRun: @unchecked Sendable {
    internal let run: ImportRun
    private let driver: DatabaseDriver
    private let databaseType: DatabaseType
    private let fileIndex: Int?
    private let targetTable: String?
    private let targetSchema: String?
    private let joinsTransaction: Bool
    private let commitMode: ConnectionCommitMode
    private let lock = NSLock()
    private var ownsTransaction = false
    private var leavesTransactionOpen = false
    private var disabledForeignKeys = false
    private var writesOutsideTransaction: Bool?
    private var finalized = false
    private var acknowledgedEnding: ImportTransactionOutcome = .untracked
    private var fileCommittedEarly = false
    private var fileRolledBack = false

    internal var transactionOutcome: ImportTransactionOutcome {
        lock.withLock {
            if acknowledgedEnding == .committed { return .committed }
            if fileCommittedEarly { return .committedBeforeRollback }
            if fileRolledBack { return .endedByFile }
            return acknowledgedEnding
        }
    }

    internal init(
        run: ImportRun,
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        fileIndex: Int?,
        targetTable: String?,
        targetSchema: String?,
        joinsTransaction: Bool,
        commitMode: ConnectionCommitMode = .automatic
    ) {
        self.run = run
        self.driver = driver
        self.databaseType = databaseType
        self.fileIndex = fileIndex
        self.targetTable = targetTable
        self.targetSchema = targetSchema
        self.joinsTransaction = joinsTransaction
        self.commitMode = commitMode
    }

    internal func prepare() async throws {
        try await admitted(.begin) {
            if self.commitMode == .manual {
                let state = await self.driver.heldSessionTransactionState()
                try ManualCommit.refuseUnheldWrite(supportsTransactions: self.driver.supportsTransactions, sessionState: state)
            }
            if !self.run.snapshot.prepared {
                let state = await self.sessionState()
                self.run.record {
                    $0.prepared = true
                    $0.initialState = state
                    $0.currentState = state
                    $0.holder = state.holdsTransaction ? .joinedUser : .none
                    $0.uncertainHistory = state == .unknown
                    let grammar = SQLLexicalResolver.readings(
                        for: self.databaseType, session: self.driver.sessionLexicalState
                    ).execution
                    $0.unseenStatements = grammar.contains(.batchSeparatorLines)
                }
            }
            guard let fileIndex = self.fileIndex else { return }
            let rollback = await self.tableRollback()
            self.run.record {
                $0.effects[fileIndex] = ImportFileEffect(index: fileIndex, table: self.targetTable, rollback: rollback)
            }
            await self.observe()
        }
    }

    private func tableRollback() async -> ImportTableRollback {
        guard driver.supportsTransactions else { return .nontransactional }
        guard let targetTable, DataSyncTransactionality.needsStorageEngines(databaseType) else {
            return .transactional
        }
        guard let metadata = try? await driver.fetchTableMetadata(tableName: targetTable, schema: targetSchema),
              let engine = metadata.engine, !engine.isEmpty else { return .unknown }
        return DataSyncTransactionality.cannotRollBack(storageEngine: engine, databaseType: databaseType)
            ? .nontransactional : .transactional
    }

    internal func data<T>(
        rows: Int = 0,
        writes: Bool = false,
        deletes: Bool = false,
        statement: String? = nil,
        interrupt: (@Sendable () -> Void)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        try await admitted(.data) {
            if writes, self.commitMode == .manual { try self.refuseWriteOutsideTransaction() }
            if let statement { self.noteStatement(statement) }
            if writes, let index = self.fileIndex {
                self.run.record { $0.effects[index]?.admittedWrite = true }
            }
            let before = self.run.snapshot.currentState
            let hadAuthority = self.lock.withLock { self.ownsTransaction }
            do {
                let value: T
                if let interrupt {
                    value = try await self.run.interruptible(by: interrupt, operation)
                } else {
                    value = try await operation()
                }
                if let index = self.fileIndex {
                    self.run.record {
                        $0.effects[index]?.submittedRows += rows
                        if statement != nil { $0.effects[index]?.statements += 1 }
                        if deletes { $0.effects[index]?.deletedRows = true }
                    }
                }
                await self.observe()
                if let statement { self.noteCompletedStatement(statement, before: before, wasOwned: hadAuthority) }
                return value
            } catch {
                self.run.record {
                    $0.recordError(error)
                    if writes, let index = self.fileIndex { $0.effects[index]?.failedWrite = true }
                }
                await self.observe()
                throw error
            }
        }
    }

    // Decided at the first write, before a GO line resets the holder: outside a transaction each statement commits.
    private func refuseWriteOutsideTransaction() throws {
        let holder = run.snapshot.holder
        let outside = lock.withLock { () -> Bool in
            if writesOutsideTransaction == nil { writesOutsideTransaction = holder == .none }
            return writesOutsideTransaction == true
        }
        if outside { throw ManualCommitUnwrappedImportRefusal() }
    }

    private func noteStatement(_ statement: String) {
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        if grammar.contains(.batchSeparatorLines) {
            lock.withLock { ownsTransaction = false }
            run.record { $0.holder = .none; $0.uncertainHistory = true }
        }
        let effect = CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar)
        let keyword = QueryClassifier.leadingKeyword(of: statement, grammar: grammar)
        if effect.endsTransaction || ["BEGIN", "START", "SAVEPOINT", "ROLLBACK", "ABORT"].contains(keyword) {
            run.record { $0.uncertainHistory = true }
        }
    }

    private func noteCompletedStatement(_ statement: String, before: ImportSessionState, wasOwned: Bool) {
        guard wasOwned else { return }
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        guard !grammar.contains(.batchSeparatorLines) else { return }
        let effect = CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar)
        let keyword = QueryClassifier.leadingKeyword(of: statement, grammar: grammar)
        let ended = before.holdsTransaction && run.snapshot.currentState == .idle
        let starts = ["BEGIN", "START"].contains(keyword)
        guard effect.endsTransaction || ended || starts else { return }
        lock.withLock {
            ownsTransaction = false
            if effect.endsTransaction || ended {
                if ["ROLLBACK", "ABORT"].contains(keyword) { fileRolledBack = true } else { fileCommittedEarly = true }
            }
        }
        run.record { $0.holder = .none; $0.uncertainHistory = true }
    }

    internal func session<T>(_ operation: () async throws -> T) async throws -> T {
        try await admitted(.session) {
            do {
                let value = try await operation()
                await self.observe(finalizing: true)
                return value
            } catch {
                self.run.record { $0.recordCleanupError(error); $0.uncertainHistory = true }
                await self.observe(finalizing: true)
                throw error
            }
        }
    }

    internal func checkpoint() async throws {
        try await admitted(.data) {}
    }

    // SQLite ignores the re-enable inside a held transaction, and a Roll Back undoes PostgreSQL's.
    internal func noteForeignKeysDisabled() {
        lock.withLock { disabledForeignKeys = true }
    }

    internal func begin() async throws {
        guard !joinsTransaction else { return }
        try await admitted(.begin) {
            let state = await self.driver.heldSessionTransactionState()
            if self.commitMode == .manual {
                guard !self.lock.withLock({ self.disabledForeignKeys }) else { throw ManualCommitForeignKeyRefusal() }
                try ManualCommit.refuseUnheldWrite(supportsTransactions: self.driver.supportsTransactions, sessionState: state)
            }
            let owner = WriteTransactionOwner.resolve(
                supportsTransactions: self.driver.supportsTransactions,
                sessionState: state,
                commitMode: self.commitMode
            )
            guard owner.sendsBegin else {
                self.run.record { $0.currentState = ImportSessionState(state) }
                return
            }
            try await self.driver.beginTransaction(mode: .readWrite)
            if owner == .held { ManualCommit.turnHold?.mark(true) }
            self.lock.withLock {
                self.ownsTransaction = true
                self.leavesTransactionOpen = !owner.commitsAtEnd
            }
            self.run.record { $0.holder = .owned; $0.ending = nil }
            await self.observe()
        }
    }

    internal func commit() async throws {
        guard mayFinalize else { return }
        guard try await run.admit(.commit) == .proceed else { return }
        defer { run.release() }
        guard mayFinalize else { return }
        let state = ImportSessionState(await driver.heldSessionTransactionState())
        if state == .aborted {
            try await finishRollback()
            return
        }
        if state == .idle {
            run.record { $0.uncertainHistory = true; $0.currentState = .idle; $0.ending = .unknown }
            lock.withLock { acknowledgedEnding = .endedByServer }
            markFinalized()
            return
        }
        // Manual Commit: the rows stay pending in a transaction that is now the user's, as a joined one is.
        if lock.withLock({ leavesTransactionOpen }) {
            lock.withLock { ownsTransaction = false }
            run.record { $0.holder = .joinedUser; $0.currentState = state }
            markFinalized()
            return
        }
        do {
            try await driver.commitTransaction()
            await recordEnding(.committed)
            lock.withLock { acknowledgedEnding = .committed }
            markFinalized()
        } catch {
            run.record { $0.recordCleanupError(error); $0.ending = .unknown }
            let after = ImportSessionState(await driver.heldSessionTransactionState())
            if after != .idle {
                do { try await finishRollback() } catch { run.record { $0.recordCleanupError(error) } }
            } else {
                run.record { $0.currentState = after; $0.uncertainHistory = true }
            }
            markFinalized()
            throw error
        }
    }

    internal func rollback() async throws {
        guard mayFinalize else { return }
        guard try await run.admit(.rollback) == .proceed else { return }
        defer { run.release() }
        guard mayFinalize else { return }
        try await finishRollback()
    }

    private var mayFinalize: Bool {
        !joinsTransaction && lock.withLock { ownsTransaction && !finalized }
    }

    private func finishRollback() async throws {
        let state = ImportSessionState(await driver.heldSessionTransactionState())
        guard state != .idle else {
            run.record { $0.uncertainHistory = true; $0.currentState = .idle; $0.ending = .unknown }
            lock.withLock { acknowledgedEnding = .endedByServer }
            markFinalized()
            return
        }
        do {
            try await driver.rollbackTransaction()
            ManualCommit.turnHold?.mark(false)
            await recordEnding(.rolledBack)
            lock.withLock { acknowledgedEnding = .rolledBack }
            markFinalized()
        } catch {
            run.record { $0.recordCleanupError(error); $0.ending = .unknown }
            await observe(finalizing: true)
            markFinalized()
            throw error
        }
    }

    private func recordEnding(_ ending: ImportLedger.Ending) async {
        let state = ImportSessionState(await driver.heldSessionTransactionState())
        run.record {
            $0.currentState = state
            $0.ending = state == .idle ? ending : .unknown
        }
    }

    private func markFinalized() {
        lock.withLock { finalized = true }
    }

    private func sessionState() async -> ImportSessionState {
        guard driver.supportsTransactions else { return .idle }
        return ImportSessionState(await driver.heldSessionTransactionState())
    }

    private func observe(finalizing: Bool = false) async {
        let state = await sessionState()
        let previous = run.snapshot.currentState
        if !finalizing, previous.holdsTransaction, state == .idle {
            let revoked = lock.withLock { () -> Bool in
                guard ownsTransaction else { return false }
                ownsTransaction = false
                acknowledgedEnding = .endedByServer
                return true
            }
            if revoked { run.record { $0.holder = .none } }
        }
        run.record { $0.observe(state, finalizing: finalizing) }
    }

    private func admitted<T>(_ kind: ImportCallKind, _ operation: () async throws -> T) async throws -> T {
        guard try await run.admit(kind) == .proceed else { throw PluginImportCancellationError() }
        defer { run.release() }
        return try await operation()
    }
}
