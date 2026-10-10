import Foundation
import Testing

@testable import TableProImport

@Suite("Connection match key")
struct ConnectionMatchKeyTests {
    @Test("Host, database and username match ignoring case and surrounding spaces")
    func normalizesTextComponents() {
        let local = ConnectionMatchKey(host: "db.example.com", port: 5_432, database: "app", username: "admin", redisDatabase: nil, socketPath: nil)
        let imported = ConnectionMatchKey(host: " DB.example.com ", port: 5_432, database: " App ", username: " ADMIN ", redisDatabase: nil, socketPath: nil)
        #expect(local == imported)
    }

    @Test("A different port or username is a different connection")
    func portAndUsernameDistinguish() {
        let base = ConnectionMatchKey(host: "h", port: 5_432, database: "app", username: "admin", redisDatabase: nil, socketPath: nil)
        #expect(base != ConnectionMatchKey(host: "h", port: 5_433, database: "app", username: "admin", redisDatabase: nil, socketPath: nil))
        #expect(base != ConnectionMatchKey(host: "h", port: 5_432, database: "app", username: "readonly", redisDatabase: nil, socketPath: nil))
    }

    @Test("Without a database name the Redis index distinguishes connections")
    func redisIndexDistinguishes() {
        let zero = ConnectionMatchKey(host: "cache", port: 6_379, database: "", username: "", redisDatabase: 0, socketPath: nil)
        let one = ConnectionMatchKey(host: "cache", port: 6_379, database: "", username: "", redisDatabase: 1, socketPath: nil)
        #expect(zero != one)
        #expect(zero == ConnectionMatchKey(host: "cache", port: 6_379, database: " ", username: "", redisDatabase: 0, socketPath: nil))
    }

    @Test("A database name takes precedence over the Redis index")
    func databaseNameWins() {
        let first = ConnectionMatchKey(host: "h", port: 1, database: "app", username: "u", redisDatabase: 1, socketPath: nil)
        let second = ConnectionMatchKey(host: "h", port: 1, database: "app", username: "u", redisDatabase: 2, socketPath: nil)
        #expect(first == second)
    }

    @Test("The settings initializer reads the same fields")
    func settingsInitializerMatches() {
        var settings = ExportableConnection(
            name: "Cache", host: "cache", port: 6_379, database: "", username: "", type: "Redis"
        )
        settings.redisDatabase = 3
        #expect(ConnectionMatchKey(settings) == ConnectionMatchKey(
            host: "cache", port: 6_379, database: "", username: "", redisDatabase: 3, socketPath: nil
        ))
    }

    @Test("A socket path is trimmed and compared exactly, and a blank one is no socket")
    func socketPathNormalization() {
        func key(_ socketPath: String?) -> ConnectionMatchKey {
            ConnectionMatchKey(
                host: "localhost", port: 3_306, database: "app", username: "root", redisDatabase: nil, socketPath: socketPath
            )
        }
        #expect(key("/tmp/mysql.sock") == key(" /tmp/mysql.sock\n"))
        #expect(key("/tmp/mysql.sock") != key("/tmp/MySQL.sock"))
        #expect(key(" ") == key(nil))
    }

    @Test("The settings initializer reads the socket path from its driver field")
    func settingsInitializerReadsSocketPath() {
        let tcp = ExportableConnection(
            name: "Local", host: "localhost", port: 3_306, database: "app", username: "root", type: "MySQL"
        )
        var socket = tcp
        socket.additionalFields = ["localSocketPath": "/tmp/mysql.sock"]
        var otherSocket = tcp
        otherSocket.additionalFields = ["localSocketPath": "/opt/homebrew/var/mysql/mysql.sock"]
        var blankSocket = tcp
        blankSocket.additionalFields = ["localSocketPath": "  "]

        #expect(ConnectionMatchKey(socket) != ConnectionMatchKey(tcp))
        #expect(ConnectionMatchKey(socket) != ConnectionMatchKey(otherSocket))
        #expect(ConnectionMatchKey(blankSocket) == ConnectionMatchKey(tcp))
    }
}
