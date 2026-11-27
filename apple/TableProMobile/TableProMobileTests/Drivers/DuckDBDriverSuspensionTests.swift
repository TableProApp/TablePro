import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

struct DuckDBDriverSuspensionTests {
    @Test("An in-memory database holds no file through a suspension")
    func inMemoryHoldsNothing() {
        #expect(!DuckDBBackedDriver(source: .inMemory).holdsSuspensionBlockingResource)
    }

    @Test("A file the session opens holds it through a suspension")
    func fileIsHeld() {
        let driver = DuckDBBackedDriver(source: .file(URL(fileURLWithPath: "/tmp/analytics.duckdb")))

        #expect(driver.holdsSuspensionBlockingResource)
    }

    @Test("The flag reaches a caller that sees only a DatabaseDriver")
    func flagReachesTheProtocol() {
        let driver: any DatabaseDriver = DuckDBBackedDriver(source: .file(URL(fileURLWithPath: "/tmp/analytics.duckdb")))

        #expect(driver.holdsSuspensionBlockingResource)
    }
}
