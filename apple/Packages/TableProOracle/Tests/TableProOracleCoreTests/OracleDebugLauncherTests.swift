import Foundation
import os
@testable import TableProOracleCore
import Testing

struct OracleDebugLauncherTests {
    private let entryPoint = OracleDebugEntryPoint(
        entry: OracleDebugEntry(unit: OracleDebugUnit(owner: "PROBE", name: "F_CALC", kind: .function), subprogram: "F_CALC", subprogramID: 1),
        overload: nil,
        parameters: [OracleDebugParameter(name: "P_A", position: 1, dataType: "NUMBER", mode: .input, hasDefault: false)],
        result: OracleDebugParameter(name: "", position: 0, dataType: "NUMBER", mode: .output, hasDefault: false)
    )

    private func launch(_ preference: OracleDebugProtocolPreference) -> OracleDebugLaunch {
        OracleDebugLaunch(
            entryPoint: entryPoint,
            arguments: ["P_A": .text("1")],
            breakpoints: [],
            preference: preference,
            debuggerHost: "127.0.0.1",
            ports: 47_300...47_399,
            databaseHost: "127.0.0.1",
            databasePort: 1_521
        )
    }

    // A start the host cancelled opens nothing, so no target is left waiting.
    @Test func testACancelledStartOpensNoSession() async {
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OracleDebugLauncher.launch(launch(.dbmsDebug)) {
                opened.withLock { $0 += 1 }
                return OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(opened.withLock { $0 } == 0)
    }

    @Test func testExplicitJDWPWithoutAHostIsRefusedBeforeAnySessionOpens() async {
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let empty = OracleDebugLaunch(
            entryPoint: entryPoint,
            arguments: ["P_A": .text("1")],
            breakpoints: [],
            preference: .jdwp,
            debuggerHost: "",
            ports: 47_300...47_399,
            databaseHost: "127.0.0.1",
            databasePort: 1_521
        )
        await #expect(throws: OracleDebugError.jdwp(.noDebuggerHost)) {
            _ = try await OracleDebugLauncher.launch(empty) {
                opened.withLock { $0 += 1 }
                return OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
            }
        }
        #expect(opened.withLock { $0 } == 0)
    }

    // Cancelled while the database has not connected back: the wait ends at once rather than at the 15 s deadline.
    @Test func testCancellingWhileWaitingForTheDatabaseEndsTheWait() async {
        let task = Task {
            try await OracleDebugLauncher.launch(launch(.jdwp)) {
                OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
            }
        }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}
