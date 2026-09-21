import Foundation
@testable import TableProMobile
import Testing

@Suite("Table browse mode")
struct TableBrowseModeTests {
    @Test("a driver that reads key contents browses keys")
    func keyContentsDriver() {
        #expect(TableBrowseMode(driver: MockKeyContentsDriver()) == .keyContents)
        #expect(TableBrowseMode.keyContentsReader(of: MockKeyContentsDriver()) != nil)
    }

    @Test("the Redis driver browses keys")
    func redisDriver() {
        #expect(TableBrowseMode(driver: RedisDriver(host: "localhost", port: 6_379, password: nil)) == .keyContents)
    }

    @Test("a SQL driver browses rows")
    func sqlDriver() {
        #expect(TableBrowseMode(driver: MockDatabaseDriver()) == .sql)
        #expect(TableBrowseMode.keyContentsReader(of: MockDatabaseDriver()) == nil)
    }

    @Test("no driver browses rows")
    func noDriver() {
        #expect(TableBrowseMode(driver: nil) == .sql)
    }
}
