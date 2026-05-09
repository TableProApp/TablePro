import Foundation
import Testing
import TableProDatabase
import TableProModels
@testable import TableProMobile

@MainActor
@Suite("ConnectionFormViewModel")
struct ConnectionFormViewModelTests {

    private func makeStoredConnection() -> DatabaseConnection {
        var conn = DatabaseConnection(
            id: UUID(),
            name: "Local",
            type: .postgresql,
            host: "10.0.0.1",
            port: 5432,
            username: "alice",
            database: "appdb",
            sshEnabled: false,
            sslEnabled: true,
            groupId: nil,
            tagId: nil
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

    @Test("createNewDatabase creates a .db URL in Documents")
    func createDatabase() {
        let vm = ConnectionFormViewModel()
        vm.type = .sqlite
        vm.newDatabaseName = "scratch"

        vm.createNewDatabase()

        #expect(vm.selectedFileURL?.lastPathComponent == "scratch.db")
        #expect(vm.database.hasSuffix("/scratch.db"))
        #expect(vm.name == "scratch")
        #expect(vm.newDatabaseName == "")
    }
}
