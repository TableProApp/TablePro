import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@Suite("SQLite driver file handling")
struct SQLiteDriverFileTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("Opening a file that is not there fails and creates nothing")
    func missingFileIsAnError() async {
        let missing = directory.appendingPathComponent("gone.db")
        let driver = SQLiteDriver(source: .file(missing))

        await #expect(throws: LocalDatabaseFileError.unavailable(fileName: "gone.db", reason: .missing)) {
            try await driver.connect()
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("A database created new reopens later with its table intact")
    func createdDatabaseReopens() async throws {
        let file = directory.appendingPathComponent("scratch.db")
        let creator = SQLiteDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        _ = try await creator.execute(query: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        _ = try await creator.execute(query: "INSERT INTO notes (body) VALUES ('kept')")
        try await creator.disconnect()

        let reopened = SQLiteDriver(source: .file(file))
        try await reopened.connect()
        let result = try await reopened.execute(query: "SELECT body FROM notes")
        try await reopened.disconnect()
        let body = result.rows.first?.first ?? nil

        #expect(body == "kept")
    }
}
