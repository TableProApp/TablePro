import Foundation
@testable import TableProOracleCore
import Testing

struct OracleConnectDeadlineTests {
    @Test func testEverySetupPhaseReadsTheSameAbsoluteDeadline() {
        let started: ContinuousClock.Instant = .now
        let deadline = OracleConnectDeadline(seconds: 60, now: started)

        #expect(abs(deadline.remainingSeconds(at: started) - (60)) <= 1e-6)
        #expect(abs((deadline.remainingSeconds(at: started.advanced(by: .seconds(7)))) - (53)) <= 1e-6)
        #expect(abs((deadline.remainingSeconds(at: started.advanced(by: .seconds(19)))) - (41)) <= 1e-6)
    }

    @Test func testAnExpiredDeadlineRefusesToStartAnotherProbe() async {
        let started: ContinuousClock.Instant = .now
        let deadline = OracleConnectDeadline(seconds: 1, now: started)
        let probes = InvocationCounter()
        let connection = OracleCoreConnection(options: OracleConnectionOptions(
            host: "127.0.0.1",
            user: "SYSTEM",
            password: "test-only",
            database: "XE"
        ))

        do {
            _ = try await connection.withConnectDeadline(
                deadline,
                now: started.advanced(by: .seconds(2))
            ) {
                probes.increment()
                return "should not run"
            }
            Issue.record("an expired connect deadline should refuse the next probe")
        } catch {
            #expect(error as? OracleCoreError == .connectTimedOut)
        }
        #expect(probes.value == 0)
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
