import Foundation
@testable import TableProOracleCore
import XCTest

final class OracleConnectDeadlineTests: XCTestCase {
    func testEverySetupPhaseReadsTheSameAbsoluteDeadline() {
        let started: ContinuousClock.Instant = .now
        let deadline = OracleConnectDeadline(seconds: 60, now: started)

        XCTAssertEqual(deadline.remainingSeconds(at: started), 60, accuracy: 1e-6)
        XCTAssertEqual(
            deadline.remainingSeconds(at: started.advanced(by: .seconds(7))),
            53,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            deadline.remainingSeconds(at: started.advanced(by: .seconds(19))),
            41,
            accuracy: 1e-6
        )
    }

    func testAnExpiredDeadlineRefusesToStartAnotherProbe() async {
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
            XCTFail("an expired connect deadline should refuse the next probe")
        } catch {
            XCTAssertEqual(error as? OracleCoreError, .connectTimedOut)
        }
        XCTAssertEqual(probes.value, 0)
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
