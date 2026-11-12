import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ImportRunTests {
    @Test("Pause waits for the last admitted write")
    func drainsLastWrite() async throws {
        let run = ImportRun()
        #expect(try await run.admit(.data) == .proceed)
        run.requestPause()
        #expect(run.currentPhase == .pausing)
        #expect(run.questionIfPaused() == nil)
        run.release()
        let question = try #require(run.questionIfPaused())
        #expect(run.currentPhase == .paused(generation: question.generation))
        run.stop(.rollBack, generation: question.generation)
        await #expect(throws: PluginImportCancellationError.self) { try await run.admit(.commit) }
        #expect(try await run.admit(.rollback) == .proceed)
        run.release()
    }

    @Test("Continue admits a parked statement exactly once")
    func continueDoesNotSkip() async throws {
        let run = ImportRun()
        run.requestPause()
        let generation = try #require(run.questionIfPaused()).generation
        let arrived = AsyncGate()
        let task = Task {
            await arrived.open()
            let admission = try await run.admit(.data)
            run.record { $0.effects[0] = ImportFileEffect(index: 0, table: "t", submittedRows: 1) }
            run.release()
            return admission
        }
        await arrived.wait()
        #expect(run.snapshot.effects.isEmpty)
        run.resume(generation: generation)
        #expect(try await task.value == .proceed)
        #expect(run.snapshot.effects[0]?.submittedRows == 1)
    }

    @Test("An unanswered question stops rather than reopening the commit path")
    func disappearanceStops() async throws {
        let run = ImportRun()
        run.requestPause()
        let generation = try #require(run.questionIfPaused()).generation
        run.stopUnansweredPause()
        #expect(!run.resume(generation: generation))
        await #expect(throws: PluginImportCancellationError.self) { try await run.admit(.commit) }
        #expect(run.stopChoice == .rollBack)
    }

    @Test("Answers from a previous question cannot stop a later pause")
    func staleAnswer() throws {
        let run = ImportRun()
        run.requestPause()
        let first = try #require(run.questionIfPaused()).generation
        run.resume(generation: first)
        run.requestPause()
        let second = try #require(run.questionIfPaused()).generation
        #expect(!run.stop(.commit, generation: first))
        #expect(!run.resume(generation: first))
        #expect(run.currentPhase == .paused(generation: second))
    }

    @Test("Cancellation before admission cannot commit or strand a waiter")
    func cancelledBeforeAdmission() async throws {
        let run = ImportRun()
        run.requestPause()
        let start = AsyncGate()
        let task = Task {
            await start.wait()
            return try await run.admit(.commit)
        }
        await start.arrived(1)
        task.cancel()
        await start.open()
        await #expect(throws: PluginImportCancellationError.self) { try await task.value }
        #expect(run.stopChoice == .rollBack)
    }

    @Test("Continue before waiter registration does not lose the wakeup")
    func resumeBeforeAdmission() async throws {
        let run = ImportRun()
        run.requestPause()
        let generation = try #require(run.questionIfPaused()).generation
        let start = AsyncGate()
        let task = Task {
            await start.wait()
            let value = try await run.admit(.data)
            run.release()
            return value
        }
        await start.arrived(1)
        run.resume(generation: generation)
        await start.open()
        #expect(try await task.value == .proceed)
    }

    @Test("Commit choice skips plugin rollback and still refuses the next write")
    func commitChoice() async throws {
        let run = ImportRun()
        run.requestPause()
        run.stop(.commit, generation: try #require(run.questionIfPaused()).generation)
        #expect(try await run.admit(.rollback) == .skip)
        #expect(try await run.admit(.commit) == .proceed)
        run.release()
        await #expect(throws: PluginImportCancellationError.self) { try await run.admit(.data) }
    }

    @Test("Finished runs refuse late writes")
    func finishRefusesWrites() async {
        let run = ImportRun()
        run.finish()
        await #expect(throws: PluginImportCancellationError.self) { try await run.admit(.data) }
        #expect(!run.requestPause())
    }
}

struct ImportStopResultTests {
    private func ledger() -> ImportLedger {
        var value = ImportLedger()
        value.prepared = true
        value.initialState = .idle
        value.currentState = .open
        value.holder = .owned
        value.effects[0] = ImportFileEffect(index: 0, table: "t", rollback: .transactional,
                                          submittedRows: 1, admittedWrite: true)
        return value
    }

    @Test("Known idle after owner rollback is not an unexplained transaction end")
    func knownRollback() {
        var value = ledger()
        value.ending = .rolledBack
        value.currentState = .idle
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .rolledBack)
    }

    @Test("A mixed batch reports each table's rollback behavior")
    func mixedTables() {
        var value = ledger()
        value.effects[1] = ImportFileEffect(index: 1, table: "other", rollback: .nontransactional,
                                          submittedRows: 2, admittedWrite: true)
        #expect(value.question.contains("other"))
        value.ending = .rolledBack
        value.currentState = .idle
        let result = ImportStopResult(ledger: value)
        #expect(result.fate(for: 0) == .rolledBack)
        #expect(result.fate(for: 1) == .kept)
    }

    @Test("Duplicate target tables keep separate file counts")
    func duplicateTargets() {
        var value = ledger()
        value.effects[1] = ImportFileEffect(index: 1, table: "t", rollback: .transactional,
                                          submittedRows: 2, admittedWrite: true)
        let result = ImportStopResult(ledger: value)
        #expect(result.fileText(for: 0).contains("1 row submitted"))
        #expect(result.fileText(for: 1).contains("2 rows submitted"))
    }

    @Test("Unseen batches and transaction history override a final COMMIT")
    func unseenHistory() {
        var value = ledger()
        value.unseenStatements = true
        value.ending = .committed
        value.currentState = .idle
        #expect(!value.canChooseCommit)
        #expect(value.question.contains("may stay"))
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .mayStay)
    }

    @Test("Failed writes into a nontransactional table keep an uncertain result")
    func partialFailure() {
        var value = ledger()
        value.effects[0]?.rollback = .nontransactional
        value.effects[0]?.failedWrite = true
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .mayStay)
    }

    @Test("A joined user transaction is never described as committed")
    func joinedTransaction() {
        var value = ledger()
        value.holder = .joinedUser
        #expect(!value.canChooseCommit)
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .openTransaction)
        value.currentState = .aborted
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .abortedTransaction)
    }

    @Test("A failed COMMIT that leaves a transaction open says so")
    func incompleteCommit() {
        var value = ledger()
        value.ending = .unknown
        #expect(ImportStopResult(ledger: value).fate(for: 0) == .mayStay)
        #expect(ImportStopResult(ledger: value).text.contains("still open"))
    }

    @Test("DELETE is visible even with no submitted rows")
    func emptyingIsAnEffect() {
        var value = ledger()
        value.effects[0]?.submittedRows = 0
        value.effects[0]?.deletedRows = true
        #expect(value.hasWrites)
        #expect(ImportStopResult(ledger: value).fileText(for: 0).contains("emptied"))
    }
}
