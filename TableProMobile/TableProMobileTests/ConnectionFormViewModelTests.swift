import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("ConnectionFormViewModel")
struct ConnectionFormViewModelTests {
    private func makeStoredConnection() -> DatabaseConnection {
        var conn = DatabaseConnection(
            id: UUID(),
            name: "Local",
            type: .postgresql,
            host: "10.0.0.1",
            port: 5_432,
            username: "alice",
            database: "appdb",
            sshEnabled: false,
            sslEnabled: true,
            groupId: nil,
            tagIds: []
        )
        conn.safeModeLevel = .readOnly
        return conn
    }

    @Test("init without editing leaves defaults and reads default safe mode")
    func newConnectionDefaults() {
        UserDefaults.standard.set(SafeModeLevel.confirmWrites.rawValue, forKey: AppPreferences.defaultSafeModeKey)
        defer { UserDefaults.standard.removeObject(forKey: AppPreferences.defaultSafeModeKey) }

        let vm = ConnectionFormViewModel()

        #expect(vm.isEditing == false)
        #expect(vm.type == .mysql)
        #expect(vm.host == "127.0.0.1")
        #expect(vm.port == "3306")
        #expect(vm.safeModeLevel == .confirmWrites)
    }

    @Test("init editing hydrates fields from connection")
    func hydration() {
        let conn = makeStoredConnection()
        let vm = ConnectionFormViewModel(editing: conn)

        #expect(vm.isEditing == true)
        #expect(vm.name == "Local")
        #expect(vm.type == .postgresql)
        #expect(vm.host == "10.0.0.1")
        #expect(vm.port == "5432")
        #expect(vm.username == "alice")
        #expect(vm.database == "appdb")
        #expect(vm.sslEnabled == true)
        #expect(vm.safeModeLevel == .readOnly)
    }

    @Test("changing type updates default port")
    func typeChangeUpdatesPort() {
        let vm = ConnectionFormViewModel()
        #expect(vm.port == "3306")

        vm.type = .postgresql
        #expect(vm.port == "5432")

        vm.type = .redis
        #expect(vm.port == "6379")

        vm.type = .sqlite
        #expect(vm.port == "")
    }

    @Test("canSave requires database for SQLite, host for server types")
    func canSaveValidation() {
        let vm = ConnectionFormViewModel()
        vm.type = .mysql
        vm.host = ""
        #expect(vm.canSave == false)

        vm.host = "localhost"
        #expect(vm.canSave == true)

        vm.type = .sqlite
        vm.database = ""
        #expect(vm.canSave == false)

        vm.database = "/tmp/test.db"
        #expect(vm.canSave == true)
    }

    @Test("loadStoredCredentials hydrates password from secure store")
    func credentialHydration() async {
        let conn = makeStoredConnection()
        let store = MockSecureStore()
        store.seed("com.TablePro.password.\(conn.id.uuidString)", "secret")
        store.seed("com.TablePro.sshpassword.\(conn.id.uuidString)", "ssh-secret")

        let vm = ConnectionFormViewModel(editing: conn)
        await vm.loadStoredCredentials(secureStore: store)

        #expect(vm.password == "secret")
        #expect(vm.sshPassword == "ssh-secret")
    }

    @Test("clearSelectedFile resets URL and database")
    func clearFile() {
        let vm = ConnectionFormViewModel()
        vm.type = .sqlite
        vm.database = "/some/path.db"
        vm.selectedFileURL = URL(fileURLWithPath: "/some/path.db")

        vm.clearSelectedFile()
        #expect(vm.selectedFileURL == nil)
        #expect(vm.database == "")
    }

    @Test("createNewDatabase stores the file's path in Documents and creates nothing yet")
    func createDatabase() throws {
        let fixture = try AppStateFixture()
        let vm = fixture.makeFormViewModel()
        vm.type = .sqlite
        vm.newDatabaseName = "scratch"

        vm.createNewDatabase()

        #expect(vm.selectedFileURL?.lastPathComponent == "scratch.db")
        #expect(vm.database == fixture.documentsFile("scratch.db").path)
        #expect(vm.name == "scratch")
        #expect(vm.newDatabaseName == "")
        #expect(vm.pendingFile == .newDocumentsFile(fixture.documentsFile("scratch.db")))
        #expect(!FileManager.default.fileExists(atPath: fixture.documentsFile("scratch.db").path))
    }

    @Test("A new database with a name already in Documents is refused")
    func createDatabaseWithTakenName() throws {
        let fixture = try AppStateFixture()
        try Data().write(to: fixture.documentsFile("scratch.db"))
        let vm = fixture.makeFormViewModel()
        vm.type = .sqlite
        vm.newDatabaseName = "scratch"

        vm.createNewDatabase()

        #expect(vm.fileError == LocalDatabaseFileError.alreadyExists(fileName: "scratch.db").localizedDescription)
        #expect(vm.database.isEmpty)
        #expect(vm.pendingFile == nil)
    }

    @Test("A file that cannot be copied in says so and leaves the form without a database")
    func failedCopyIsReported() throws {
        let fixture = try AppStateFixture()
        let vm = fixture.makeFormViewModel()
        vm.type = .sqlite

        vm.handleSQLiteFilePicker(.success([fixture.root.appendingPathComponent("missing.db")]))

        #expect(vm.fileError != nil)
        #expect(vm.database.isEmpty)
        #expect(vm.selectedFileURL == nil)
    }

    @Test("A picked SQLite file is copied into Documents and stored by its path there")
    func pickedFileIsCopied() throws {
        let fixture = try AppStateFixture()
        let source = fixture.root.appendingPathComponent("orders.sqlite")
        try Data("orders".utf8).write(to: source)
        let vm = fixture.makeFormViewModel()
        vm.type = .sqlite

        vm.handleSQLiteFilePicker(.success([source]))

        #expect(vm.database == fixture.documentsFile("orders.sqlite").path)
        #expect(vm.pendingFile == .documentsFile)
        #expect(FileManager.default.fileExists(atPath: fixture.documentsFile("orders.sqlite").path))
    }

    @Test("A file connection from before a restore shows today's file and keeps its stored path")
    func restoredFileHydrates() throws {
        let fixture = try AppStateFixture()
        let storedPath = fixture.earlierContainerPath(to: "notes.db")
        let vm = fixture.makeFormViewModel(
            editing: DatabaseConnection(type: .sqlite, port: 0, database: storedPath)
        )

        #expect(vm.selectedFileURL == fixture.documentsFile("notes.db"))
        #expect(vm.database == storedPath)
    }

    @Test("A file connection synced from another device is not shown as a file on this one")
    func otherDeviceFileIsNotReRooted() throws {
        let fixture = try AppStateFixture()
        let storedPath = fixture.otherInstallContainerPath(to: "notes.db")
        let vm = fixture.makeFormViewModel(
            editing: DatabaseConnection(type: .sqlite, port: 0, database: storedPath)
        )

        #expect(vm.selectedFileURL == URL(fileURLWithPath: storedPath))
        #expect(vm.database == storedPath)
    }
}
