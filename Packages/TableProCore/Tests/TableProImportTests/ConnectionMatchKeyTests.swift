import Foundation
import Testing

@testable import TableProImport

@Suite("Connection match key")
struct ConnectionMatchKeyTests {
    @Test("Host, database and username match ignoring case and surrounding spaces")
    func normalizesTextComponents() {
        let local = ConnectionMatchKey(host: "db.example.com", port: 5_432, database: "app", username: "admin", redisDatabase: nil)
        let imported = ConnectionMatchKey(host: " DB.example.com ", port: 5_432, database: " App ", username: " ADMIN ", redisDatabase: nil)
        #expect(local == imported)
    }

    @Test("A different port or username is a different connection")
    func portAndUsernameDistinguish() {
        let base = ConnectionMatchKey(host: "h", port: 5_432, database: "app", username: "admin", redisDatabase: nil)
        #expect(base != ConnectionMatchKey(host: "h", port: 5_433, database: "app", username: "admin", redisDatabase: nil))
        #expect(base != ConnectionMatchKey(host: "h", port: 5_432, database: "app", username: "readonly", redisDatabase: nil))
    }

    @Test("Without a database name the Redis index distinguishes connections")
    func redisIndexDistinguishes() {
        let zero = ConnectionMatchKey(host: "cache", port: 6_379, database: "", username: "", redisDatabase: 0)
        let one = ConnectionMatchKey(host: "cache", port: 6_379, database: "", username: "", redisDatabase: 1)
        #expect(zero != one)
        #expect(zero == ConnectionMatchKey(host: "cache", port: 6_379, database: " ", username: "", redisDatabase: 0))
    }

    @Test("A database name takes precedence over the Redis index")
    func databaseNameWins() {
        let first = ConnectionMatchKey(host: "h", port: 1, database: "app", username: "u", redisDatabase: 1)
        let second = ConnectionMatchKey(host: "h", port: 1, database: "app", username: "u", redisDatabase: 2)
        #expect(first == second)
    }

    @Test("The settings initializer reads the same fields")
    func settingsInitializerMatches() {
        var settings = ExportableConnection(
            name: "Cache", host: "cache", port: 6_379, database: "", username: "", type: "Redis"
        )
        settings.redisDatabase = 3
        #expect(ConnectionMatchKey(settings) == ConnectionMatchKey(
            host: "cache", port: 6_379, database: "", username: "", redisDatabase: 3
        ))
    }
}
