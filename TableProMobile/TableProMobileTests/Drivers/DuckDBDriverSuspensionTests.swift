import XCTest
@testable import TableProMobile

final class DuckDBDriverSuspensionTests: XCTestCase {
    func testInMemoryDatabaseHoldsNoSuspensionBlockingResource() {
        let driver = DuckDBDriver(path: DuckDBDriver.inMemoryPath, bookmark: nil)

        XCTAssertFalse(driver.holdsSuspensionBlockingResource)
    }

    func testFileBackedDatabaseHoldsSuspensionBlockingResource() {
        let driver = DuckDBDriver(path: "/tmp/analytics.duckdb", bookmark: nil)

        XCTAssertTrue(driver.holdsSuspensionBlockingResource)
    }
}
