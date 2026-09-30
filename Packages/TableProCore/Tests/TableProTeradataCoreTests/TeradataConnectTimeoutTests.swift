@testable import TableProTeradataCore
import XCTest

final class TeradataConnectTimeoutTests: XCTestCase {
    func testMillisecondConfigKeepsTheNativeBudget() {
        let config = TeradataConnectionConfig(
            host: "db.example.com",
            username: "user",
            password: "secret",
            connectTimeoutMilliseconds: 4_321
        )

        XCTAssertEqual(config.connectTimeoutMilliseconds, 4_321)
        XCTAssertEqual(config.connectTimeoutSeconds, 5)
    }

    func testLegacySecondsAndExtremeValuesAreClamped() {
        let legacy = TeradataConnectionConfig(
            host: "db.example.com",
            username: "user",
            password: "secret",
            connectTimeoutSeconds: 12
        )
        var clamped = legacy
        clamped.connectTimeoutSeconds = Int.max
        var negativeClamped = legacy
        negativeClamped.connectTimeoutSeconds = Int.min

        XCTAssertEqual(legacy.connectTimeoutMilliseconds, 12_000)
        XCTAssertEqual(clamped.connectTimeoutMilliseconds, 3_600_000)
        XCTAssertEqual(negativeClamped.connectTimeoutMilliseconds, 1)
    }

    func testOneDeadlineShrinksAcrossTransportAndAuthentication() throws {
        let deadline = TeradataConnectDeadline(milliseconds: 4_250, now: 100)

        XCTAssertEqual(try deadline.remainingMilliseconds(now: 101.25), 3_000)
        XCTAssertThrowsError(try deadline.remainingMilliseconds(now: 104.25))
    }

    func testSocketTimeoutPreservesMillisecondPrecision() {
        let timeout = TeradataSocket.socketTimeout(milliseconds: 4_321)

        XCTAssertEqual(timeout.tv_sec, 4)
        XCTAssertEqual(timeout.tv_usec, 321_000)
    }
}
