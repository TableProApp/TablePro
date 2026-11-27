import Foundation
import TableProPluginKit
import Testing

// The host checks a database a caller names against this report, the only evidence of which file a statement reaches.
struct SQLiteReportedDatabaseTests {
    @Test("The driver reports the file it opened, as the connection names it")
    func reportsTheFileItOpened() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-reported-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("prod.sqlite").path
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path
        ))

        try await driver.connect()
        defer { driver.disconnect() }

        #expect(driver.currentDatabase == path)
    }
}
