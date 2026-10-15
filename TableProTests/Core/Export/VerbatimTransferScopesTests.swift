//
//  VerbatimTransferScopesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private struct ScopeFailure: Error {}

private final class ScopeDriver: PluginDriverStub, @unchecked Sendable {
    enum Answer {
        case scope
        case missing
        case failure
    }

    private let lock = NSLock()
    private var log: [String] = []
    private var cancelledAtClose: [Bool] = []
    private let answer: Answer
    private let failsClose: Bool

    init(answer: Answer = .scope, failsClose: Bool = false) {
        self.answer = answer
        self.failsClose = failsClose
    }

    var events: [String] { lock.withLock { log } }
    var closesSawCancellation: [Bool] { lock.withLock { cancelledAtClose } }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        lock.withLock { log.append("open \(purpose)") }
        switch answer {
        case .scope:
            return PluginSessionScope(
                purpose: purpose, saved: [], applied: [PluginSessionSetting(name: "time_zone", value: "+00:00")])
        case .missing:
            return nil
        case .failure:
            throw ScopeFailure()
        }
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        let isCancelled = Task.isCancelled
        lock.withLock {
            log.append("close \(scope.purpose)")
            cancelledAtClose.append(isCancelled)
        }
        if failsClose { throw ScopeFailure() }
    }
}

/// One session's `sql_mode`, saved and set by each scope the way a driver does it.
private final class OneSessionDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: String

    init(mode: String) {
        self.mode = mode
    }

    var currentMode: String { lock.withLock { mode } }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        let applied = "\(purpose)"
        let saved = lock.withLock {
            defer { mode = applied }
            return mode
        }
        return PluginSessionScope(
            purpose: purpose,
            saved: [PluginSessionSetting(name: "sql_mode", value: saved)],
            applied: [PluginSessionSetting(name: "sql_mode", value: applied)]
        )
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        guard let saved = scope.saved.first?.value else { return }
        lock.withLock { mode = saved }
    }
}

struct VerbatimTransferScopesTests {
    private func openPair(_ source: ScopeDriver, _ target: ScopeDriver) async -> VerbatimTransferScopes? {
        await VerbatimTransferScopes.open(reading: SessionScopeHandle(source), writing: SessionScopeHandle(target))
    }

    @Test("A pair opens read on the source and write on the target, and closes both")
    func pairOpensAndClosesBothSides() async throws {
        let source = ScopeDriver()
        let target = ScopeDriver()

        let scopes = try #require(await openPair(source, target))
        #expect(source.events == ["open verbatimRead"])
        #expect(target.events == ["open verbatimWrite"])

        await scopes.close()
        #expect(source.events == ["open verbatimRead", "close verbatimRead"])
        #expect(target.events == ["open verbatimWrite", "close verbatimWrite"])
    }

    @Test("A target with no scope, or one that fails to open, leaves the source closed and no pair")
    func targetWithoutScopeClosesSource() async {
        for answer in [ScopeDriver.Answer.missing, .failure] {
            let source = ScopeDriver()
            let target = ScopeDriver(answer: answer)

            let scopes = await openPair(source, target)

            #expect(scopes == nil)
            #expect(source.events == ["open verbatimRead", "close verbatimRead"])
            #expect(target.events == ["open verbatimWrite"])
        }
    }

    @Test("A source with no scope, or one that fails to open, never touches the target")
    func sourceWithoutScopeLeavesTargetAlone() async {
        for answer in [ScopeDriver.Answer.missing, .failure] {
            let source = ScopeDriver(answer: answer)
            let target = ScopeDriver()

            let scopes = await openPair(source, target)

            #expect(scopes == nil)
            #expect(source.events == ["open verbatimRead"])
            #expect(target.events.isEmpty)
        }
    }

    @Test("A close that fails still closes the other side")
    func failedCloseStillClosesTheOtherSide() async throws {
        let source = ScopeDriver()
        let target = ScopeDriver(failsClose: true)

        let scopes = try #require(await openPair(source, target))
        await scopes.close()

        #expect(target.events.last == "close verbatimWrite")
        #expect(source.events.last == "close verbatimRead")
    }

    @Test("The write-only scope opens one side")
    func writeOnlyOpensOneSide() async throws {
        let target = ScopeDriver()

        let scopes = try #require(await VerbatimTransferScopes.open(writing: SessionScopeHandle(target)))
        await scopes.close()

        #expect(target.events == ["open verbatimWrite", "close verbatimWrite"])
    }

    /// A Stop cancels the task that runs the copy, and a driver that checks for cancellation would
    /// otherwise skip the statement that puts the session back.
    @Test("Closing from a cancelled task reaches the driver outside the cancellation")
    func closeIsShieldedFromCancellation() async throws {
        let source = ScopeDriver()
        let target = ScopeDriver()
        let scopes = try #require(await openPair(source, target))

        let closing = Task {
            withUnsafeCurrentTask { task in
                guard let task else { return }
                task.cancel()
            }
            await scopes.close()
        }
        await closing.value

        #expect(source.closesSawCancellation == [false])
        #expect(target.closesSawCancellation == [false])
    }

    /// An unpooled engine serves both sides from one session, and closing in opening order left it
    /// on the read scope's settings.
    @Test("Scopes on one session close in reverse order and leave it as it was")
    func oneSessionIsRestoredInReverseOrder() async throws {
        let session = OneSessionDriver(mode: "STRICT_TRANS_TABLES")

        let scopes = try #require(await VerbatimTransferScopes.open(
            reading: SessionScopeHandle(session), writing: SessionScopeHandle(session)
        ))
        #expect(session.currentMode == "verbatimWrite")

        await scopes.close()
        #expect(session.currentMode == "STRICT_TRANS_TABLES")
    }

    @Test("Only a row filter keeps the sessions as they are")
    func onlyARowFilterCounts() {
        #expect(VerbatimTransferScopes.filtersRows(PluginExportRowScope(filter: "id > 5")))
        #expect(VerbatimTransferScopes.filtersRows(PluginExportRowScope(filter: "id > 5;", rowLimit: 3)))
        #expect(!VerbatimTransferScopes.filtersRows(PluginExportRowScope(rowLimit: 10)))
        #expect(!VerbatimTransferScopes.filtersRows(PluginExportRowScope(columns: ["id"])))
        #expect(!VerbatimTransferScopes.filtersRows(PluginExportRowScope(filter: "   ")))
        #expect(!VerbatimTransferScopes.filtersRows(nil))
    }

    @Test("Same engine follows Object Copy's type families")
    func sameEngineFollowsTypeFamilies() {
        #expect(VerbatimTransferScopes.isSameEngine(source: .mysql, target: .mysql))
        #expect(VerbatimTransferScopes.isSameEngine(source: .mariadb, target: .mysql))
        #expect(VerbatimTransferScopes.isSameEngine(source: .postgresql, target: .postgresql))
        #expect(!VerbatimTransferScopes.isSameEngine(source: .postgresql, target: .mysql))
        #expect(!VerbatimTransferScopes.isSameEngine(source: .mysql, target: .sqlite))

        let unnamed = DatabaseType(rawValue: "PluginOnlyEngine")
        #expect(VerbatimTransferScopes.isSameEngine(source: unnamed, target: unnamed))
        #expect(!VerbatimTransferScopes.isSameEngine(source: unnamed, target: DatabaseType(rawValue: "OtherPluginEngine")))
    }
}
