import Foundation
@testable import TablePro
import Testing

@Suite("MongoDBAuthSourceResolver")
struct MongoDBAuthSourceResolverTests {
    @Test("An explicit auth source wins over everything else")
    func testExplicitWins() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: "accounts",
            configuredDatabase: "shop",
            useSrv: false
        )
        #expect(resolved == "accounts")
    }

    @Test("A blank explicit auth source falls through")
    func testBlankExplicitFallsThrough() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: "",
            configuredDatabase: "shop",
            useSrv: false
        )
        #expect(resolved == "shop")
    }

    @Test("SRV connections authenticate against admin")
    func testSrvUsesAdmin() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: nil,
            configuredDatabase: "shop",
            useSrv: true
        )
        #expect(resolved == "admin")
    }

    @Test("Without a configured database the fallback is admin")
    func testEmptyConfiguredUsesAdmin() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: nil,
            configuredDatabase: "",
            useSrv: false
        )
        #expect(resolved == "admin")
    }

    @Test("A configured database is the fallback when no auth source is set")
    func testConfiguredDatabaseIsFallback() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: nil,
            configuredDatabase: "shop",
            useSrv: false
        )
        #expect(resolved == "shop")
    }
}
