import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Connection info content")
struct ConnectionInfoContentTests {
    @Test("A DuckDB file connection gets the File section with its name and path")
    func duckDBFile() {
        let connection = DatabaseConnection(type: .duckdb, host: "127.0.0.1", port: 3_306, database: "/x/a.duckdb")

        let section = ConnectionInfoContent.section(for: connection, fileURL: URL(fileURLWithPath: "/x/a.duckdb"))

        #expect(section == .file(ConnectionFileDetail(name: "a.duckdb", path: "/x/a.duckdb")))
    }

    @Test("An in-memory DuckDB connection says In Memory instead of a path")
    func duckDBInMemory() {
        let connection = DatabaseConnection(
            type: .duckdb,
            host: "127.0.0.1",
            port: 3_306,
            database: LocalDatabaseLocation.inMemoryPath
        )

        let section = ConnectionInfoContent.section(for: connection, fileURL: nil)

        #expect(section == .file(ConnectionFileDetail(name: String(localized: "In Memory"), path: nil)))
    }

    @Test("A SQLite connection gets the File section")
    func sqliteFile() {
        let connection = DatabaseConnection(type: .sqlite, database: "/var/mobile/Documents/app.sqlite")

        let section = ConnectionInfoContent.section(
            for: connection,
            fileURL: URL(fileURLWithPath: "/var/mobile/Documents/app.sqlite")
        )

        #expect(section == .file(ConnectionFileDetail(name: "app.sqlite", path: "/var/mobile/Documents/app.sqlite")))
    }

    @Test("A server connection gets the Server section")
    func serverConnection() {
        let connection = DatabaseConnection(type: .postgresql, host: "db.acme.io", port: 5_432, database: "app")

        #expect(ConnectionInfoContent.section(for: connection, fileURL: nil) == .server)
    }

    @Test("Only SQLite and DuckDB are local file engines", arguments: DatabaseType.mobileSupportedTypes)
    func localFileEngines(type: DatabaseType) {
        #expect(type.isLocalFile == (type == .sqlite || type == .duckdb))
    }
}
