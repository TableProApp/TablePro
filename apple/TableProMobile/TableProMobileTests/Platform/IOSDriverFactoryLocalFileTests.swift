import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@Suite("Driver factory with local database files")
struct IOSDriverFactoryLocalFileTests {
    private let root: URL
    private let documentsDirectory: URL
    private let bookmarkStore: FileBookmarkStore
    private let history: AppContainerHistory

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("driver-factory-\(UUID().uuidString)", isDirectory: true)
        documentsDirectory = root
            .appendingPathComponent("Data/Application/\(UUID().uuidString)/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        bookmarkStore = FileBookmarkStore(suiteName: "com.TablePro.tests.FactoryBookmarks.\(UUID().uuidString)")
        history = AppContainerHistory(suiteName: "com.TablePro.tests.FactoryContainers.\(UUID().uuidString)")
    }

    private var factory: IOSDriverFactory {
        IOSDriverFactory(
            bookmarkStore: bookmarkStore,
            localFiles: LocalDatabaseFileLocator(
                container: AppContainerPaths(documentsDirectory: documentsDirectory, history: history)
            )
        )
    }

    private func pathInContainer(_ containerId: String, _ fileName: String) -> String {
        documentsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("\(containerId)/Documents/\(fileName)")
            .path
    }

    private func createSQLiteFile(_ fileName: String) async throws {
        let creator = SQLiteBackedDriver(
            source: .file(documentsDirectory.appendingPathComponent(fileName)),
            openMode: .createNew
        )
        try await creator.connect()
        try await creator.disconnect()
    }

    @Test("A connection restored with a path into this install's old container opens the file in Documents")
    func restoredPathOpens() async throws {
        try await createSQLiteFile("notes.db")
        let earlier = UUID().uuidString
        history.record(earlier)
        let connection = DatabaseConnection(type: .sqlite, port: 0, database: pathInContainer(earlier, "notes.db"))

        let driver = try factory.createDriver(for: connection, password: nil)
        try await driver.connect()
        try await driver.disconnect()
    }

    @Test("A path synced from another device never opens this device's file of the same name")
    func otherDevicePathDoesNotOpenLocalFile() async throws {
        try await createSQLiteFile("test.db")
        let connection = DatabaseConnection(
            type: .sqlite,
            port: 0,
            database: pathInContainer(UUID().uuidString, "test.db")
        )

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "test.db", reason: .notOnThisDevice)) {
            try factory.createDriver(for: connection, password: nil)
        }
    }

    @Test("A missing file in Documents is an error, and no empty database takes its place")
    func missingFileThrows() throws {
        let missing = documentsDirectory.appendingPathComponent("gone.db")
        let connection = DatabaseConnection(type: .sqlite, port: 0, database: missing.path)

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "gone.db", reason: .missing)) {
            try factory.createDriver(for: connection, password: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("A bare file name is never looked up in Documents")
    func bareFileNameIsNotOnThisDevice() async throws {
        try await createSQLiteFile("notes.db")
        let connection = DatabaseConnection(type: .sqlite, port: 0, database: "notes.db")

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "notes.db", reason: .notOnThisDevice)) {
            try factory.createDriver(for: connection, password: nil)
        }
    }

    @Test("A Mac path is not on this device")
    func macPathThrows() {
        let connection = DatabaseConnection(type: .duckdb, port: 0, database: "/Users/mac/warehouse.duckdb")

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "warehouse.duckdb", reason: .notOnThisDevice)) {
            try factory.createDriver(for: connection, password: nil)
        }
    }

    @Test("A Mac connection's attached databases and extensions are not opened on iOS")
    func macOnlyFieldsAreNotOpened() async throws {
        try await createSQLiteFile("main.db")
        let connection = DatabaseConnection(
            type: .sqlite,
            port: 0,
            database: documentsDirectory.appendingPathComponent("main.db").path,
            additionalFields: [
                AttachedDatabaseList.fieldId: #"[{"name":"side","path":"/Users/mac/side.db"}]"#,
                LoadableExtensionList.fieldId: #"[{"path":"/opt/homebrew/lib/vec0.dylib"}]"#,
            ]
        )

        let driver = try factory.createDriver(for: connection, password: nil)
        try await driver.connect()
        let databases = try await driver.execute(query: "SELECT name FROM pragma_database_list ORDER BY seq").rows
        try await driver.disconnect()

        #expect(databases == [["main"]])
    }

    @Test("A bookmark left over from an earlier pick is ignored for a DuckDB file in Documents")
    func lingeringBookmarkIsIgnored() async throws {
        let file = documentsDirectory.appendingPathComponent("cube.duckdb")
        let creator = DuckDBBackedDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        try await creator.disconnect()
        let connection = DatabaseConnection(type: .duckdb, port: 0, database: file.path)
        bookmarkStore.save(Data("not a bookmark".utf8), for: connection.id)

        let driver = try factory.createDriver(for: connection, password: nil)
        try await driver.connect()
        try await driver.disconnect()
    }
}
