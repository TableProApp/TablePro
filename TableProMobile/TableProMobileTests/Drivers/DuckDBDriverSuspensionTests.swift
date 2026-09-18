@testable import TableProMobile
import XCTest

final class DuckDBDriverSuspensionTests: XCTestCase {
    func testInMemoryDatabaseHoldsNoSuspensionBlockingResource() {
        let driver = DuckDBDriver(source: .inMemory)

        XCTAssertFalse(driver.holdsSuspensionBlockingResource)
    }

    func testFileBackedDatabaseHoldsSuspensionBlockingResource() {
        let driver = DuckDBDriver(source: .file(URL(fileURLWithPath: "/tmp/analytics.duckdb")))

        XCTAssertTrue(driver.holdsSuspensionBlockingResource)
    }
}
