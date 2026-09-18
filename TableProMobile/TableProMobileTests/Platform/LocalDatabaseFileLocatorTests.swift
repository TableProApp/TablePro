import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Local database file locator")
struct LocalDatabaseFileLocatorTests {
    private let family = "/var/mobile/Containers/Data/Application"
    private let current = "11111111-1111-1111-1111-111111111111"
    private let earlier = "22222222-2222-2222-2222-222222222222"
    private let otherInstall = "33333333-3333-3333-3333-333333333333"
    private let history: AppContainerHistory

    init() {
        history = AppContainerHistory(suiteName: "com.TablePro.tests.LocatorContainers.\(UUID().uuidString)")
        history.record(earlier)
    }

    private var documents: String { "\(family)/\(current)/Documents" }

    private func locator(existing: Set<String> = []) -> LocalDatabaseFileLocator {
        LocalDatabaseFileLocator(
            container: AppContainerPaths(documentsDirectory: URL(fileURLWithPath: documents), history: history)
        ) { existing.contains($0) }
    }

    @Test("Stored paths map to this install's files, files elsewhere, or nothing on this device")
    func storedPathsMapToLocations() {
        let files = locator()

        #expect(files.location(forStoredPath: LocalDatabaseLocation.inMemoryPath) == .inMemory)
        #expect(
            files.location(forStoredPath: "\(documents)/fresh.db")
                == .appFile(URL(fileURLWithPath: "\(documents)/fresh.db"))
        )
        #expect(
            files.location(forStoredPath: "\(family)/\(earlier)/Documents/notes.db")
                == .appFile(URL(fileURLWithPath: "\(documents)/notes.db"))
        )
        #expect(
            files.location(forStoredPath: "/Users/mac/app.db") == .externalFile(URL(fileURLWithPath: "/Users/mac/app.db"))
        )
        let foreign = "\(family)/\(otherInstall)/Documents/shared.db"
        #expect(files.location(forStoredPath: foreign) == .notOnThisDevice(storedPath: foreign))
        #expect(files.location(forStoredPath: "notes.db") == .notOnThisDevice(storedPath: "notes.db"))
        #expect(files.location(forStoredPath: "~/app.db") == .notOnThisDevice(storedPath: "~/app.db"))
    }

    @Test("Another install's path never opens this device's file of the same name")
    func otherInstallNeverBindsToALocalFile() {
        let foreign = "\(family)/\(otherInstall)/Documents/data.duckdb"
        let files = locator(existing: [foreign, "\(documents)/data.duckdb"])

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "data.duckdb", reason: .notOnThisDevice)) {
            try files.existingSource(for: files.location(forStoredPath: foreign))
        }
    }

    @Test("A missing file in this install and an unreachable Mac path both surface as unavailable")
    func missingFilesThrow() {
        let files = locator()

        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "notes.db", reason: .missing)) {
            try files.existingSource(for: .appFile(URL(fileURLWithPath: "\(documents)/notes.db")))
        }
        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "app.db", reason: .notOnThisDevice)) {
            try files.existingSource(for: .externalFile(URL(fileURLWithPath: "/Users/mac/app.db")))
        }
        #expect(throws: LocalDatabaseFileError.unavailable(fileName: "app.db", reason: .notOnThisDevice)) {
            try files.existingSource(for: .notOnThisDevice(storedPath: "~/app.db"))
        }
    }

    @Test("An existing file resolves to its URL, and in-memory needs no file")
    func existingFilesResolve() throws {
        let files = locator(existing: ["\(documents)/notes.db"])

        #expect(
            try files.existingSource(for: files.location(forStoredPath: "\(family)/\(earlier)/Documents/notes.db"))
                == .file(URL(fileURLWithPath: "\(documents)/notes.db"))
        )
        #expect(try files.existingSource(for: .inMemory) == .inMemory)
    }

    @Test("A new database name is checked before anything is created")
    func newDatabaseNamesAreValidated() throws {
        let files = locator(existing: ["\(documents)/taken.db"])

        #expect(try files.newDatabaseFile(named: " scratch ", type: .sqlite).lastPathComponent == "scratch.db")
        #expect(try files.newDatabaseFile(named: "cube.duckdb", type: .duckdb).lastPathComponent == "cube.duckdb")
        #expect(throws: LocalDatabaseFileError.invalidName) {
            try files.newDatabaseFile(named: "  ", type: .sqlite)
        }
        #expect(throws: LocalDatabaseFileError.invalidName) {
            try files.newDatabaseFile(named: "a/b", type: .sqlite)
        }
        #expect(throws: LocalDatabaseFileError.invalidName) {
            try files.newDatabaseFile(named: ".hidden", type: .sqlite)
        }
        #expect(throws: LocalDatabaseFileError.alreadyExists(fileName: "taken.db")) {
            try files.newDatabaseFile(named: "taken", type: .sqlite)
        }
    }

    @Test("An imported copy never overwrites a file, and a copy that fails says so")
    func importCopyIsSafe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("orders.db")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: documentsDirectory.appendingPathComponent("orders.db"))
        let files = LocalDatabaseFileLocator(
            container: AppContainerPaths(documentsDirectory: documentsDirectory, history: history)
        )

        let copy = try files.importCopy(of: source)

        #expect(copy.lastPathComponent != "orders.db")
        #expect(copy.pathExtension == "db")
        #expect(try Data(contentsOf: copy) == Data("new".utf8))
        #expect(try Data(contentsOf: documentsDirectory.appendingPathComponent("orders.db")) == Data("old".utf8))
        #expect(throws: LocalDatabaseFileError.self) {
            try files.importCopy(of: root.appendingPathComponent("missing.db"))
        }
        #expect(files.isInDocuments(copy))
    }
}
