//
//  RoutineDebugSessionSourceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    private var closes = 0

    var executed: [String] { lock.withLock { statements } }
    var closedCount: Int { lock.withLock { closes } }

    func record(_ statement: String) { lock.withLock { statements.append(statement) } }
    func recordClose() { lock.withLock { closes += 1 } }
}

private final class StatementDriver: PluginDriverStub, @unchecked Sendable {
    let log: StatementLog

    init(log: StatementLog) {
        self.log = log
    }

    func execute(query: String) async throws -> PluginQueryResult {
        log.record(query)
        return .empty
    }
}

@MainActor
struct RoutineDebugSessionSourceTests {
    @Test("A preparation's statements run in order on a driver of their own, which is closed after")
    func preparationUsesAndClosesItsOwnDriver() async throws {
        let log = StatementLog()
        let source = RoutineDebugSessionSource {
            RoutineDebugDriverHandle(driver: StatementDriver(log: log)) { log.recordClose() }
        }

        try await source.run(["ALTER PACKAGE p COMPILE", "ALTER PACKAGE p COMPILE BODY"])
        await source.closeAll()

        #expect(log.executed == ["ALTER PACKAGE p COMPILE", "ALTER PACKAGE p COMPILE BODY"])
        #expect(log.closedCount == 1)
    }

    @Test("A driver still dialing when the session ends is closed and refused, never handed to the plugin")
    func lateDriverIsClosed() async throws {
        let log = StatementLog()
        let dialing = AsyncGate()
        let source = RoutineDebugSessionSource {
            await dialing.wait()
            return RoutineDebugDriverHandle(driver: StatementDriver(log: log)) { log.recordClose() }
        }

        let opening = Task { try await source.openSession() }
        await dialing.arrived(1)
        await source.closeAll()
        await dialing.open()

        await #expect(throws: RoutineDebugError.sessionEnded) { _ = try await opening.value }
        #expect(log.closedCount == 1)
        await #expect(throws: RoutineDebugError.sessionEnded) { _ = try await source.openSession() }
    }

    @Test("Ending the session closes every driver it opened, once")
    func closeAllClosesEachDriverOnce() async throws {
        let log = StatementLog()
        let source = RoutineDebugSessionSource {
            RoutineDebugDriverHandle(driver: StatementDriver(log: log)) { log.recordClose() }
        }

        _ = try await source.openSession()
        _ = try await source.openSession()
        await source.closeAll()
        await source.closeAll()

        #expect(log.closedCount == 2)
    }
}
