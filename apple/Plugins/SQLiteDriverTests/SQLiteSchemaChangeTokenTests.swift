import Foundation
import TableProPluginKit
import Testing

struct SQLiteSchemaChangeTokenTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-schema-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func connect() async throws -> SQLitePluginDriver {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "",
            database: directory.appendingPathComponent("app.db").path
        ))
        try await driver.connect()
        return driver
    }

    @Test("Writing rows leaves the token alone, and another connection's schema change moves it")
    func tokenFollowsSchemaNotData() async throws {
        let watcher = try await connect()
        let writer = try await connect()
        defer {
            watcher.disconnect()
            writer.disconnect()
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try await writer.execute(query: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

        let before = try #require(try await watcher.schemaChangeToken())
        _ = try await writer.execute(query: "INSERT INTO users (name) VALUES ('a')")
        _ = try await writer.execute(query: "UPDATE users SET name = 'b'")
        #expect(try await watcher.schemaChangeToken() == before)

        _ = try await writer.execute(query: "CREATE INDEX users_name ON users (name)")
        let after = try #require(try await watcher.schemaChangeToken())
        #expect(after != before)
    }
}
