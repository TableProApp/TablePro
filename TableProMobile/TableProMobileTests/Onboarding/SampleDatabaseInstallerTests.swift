import Foundation
@testable import TableProMobile
import Testing

@Suite("Sample database installer")
struct SampleDatabaseInstallerTests {
    private static let sqliteSidecarSuffixes = ["-journal", "-wal", "-shm"]

    private let directory: URL
    private let bundled: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundled = root.appendingPathComponent("Bundled.sqlite")
        try Data("original".utf8).write(to: bundled)
        directory = root.appendingPathComponent("Samples", isDirectory: true)
    }

    @Test("The app bundle carries the sample database")
    func bundleCarriesSample() throws {
        let url = try #require(SampleDatabaseInstaller.live.bundledURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Install copies once and keeps the user's changes after that")
    func installKeepsChanges() throws {
        let installer = SampleDatabaseInstaller(bundledURL: bundled, directory: directory)

        let installed = try installer.installIfNeeded()
        try Data("edited".utf8).write(to: installed)
        try installer.installIfNeeded()

        #expect(try String(contentsOf: installed, encoding: .utf8) == "edited")
    }

    @Test("Reset restores the original and removes the journal files")
    func resetRemovesSidecars() throws {
        let installer = SampleDatabaseInstaller(bundledURL: bundled, directory: directory)
        let installed = try installer.installIfNeeded()
        try Data("edited".utf8).write(to: installed)
        for suffix in Self.sqliteSidecarSuffixes {
            try Data("stale".utf8).write(to: URL(fileURLWithPath: installed.path + suffix))
        }

        try installer.reset()

        #expect(try String(contentsOf: installed, encoding: .utf8) == "original")
        for suffix in Self.sqliteSidecarSuffixes {
            #expect(!FileManager.default.fileExists(atPath: installed.path + suffix))
        }
    }

    @Test("Installing over journal files a failed reset left behind removes them first")
    func installRemovesOrphanedSidecars() throws {
        let installer = SampleDatabaseInstaller(bundledURL: bundled, directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for suffix in Self.sqliteSidecarSuffixes {
            try Data("stale".utf8).write(to: URL(fileURLWithPath: installer.installedURL.path + suffix))
        }

        let installed = try installer.installIfNeeded()

        #expect(try String(contentsOf: installed, encoding: .utf8) == "original")
        for suffix in Self.sqliteSidecarSuffixes {
            #expect(!FileManager.default.fileExists(atPath: installed.path + suffix))
        }
    }

    @Test("A missing bundle is an error, never an empty database")
    func missingBundle() {
        let installer = SampleDatabaseInstaller(bundledURL: nil, directory: directory)

        #expect(throws: SampleDatabaseError.bundleMissing) {
            try installer.installIfNeeded()
        }
        #expect(!FileManager.default.fileExists(atPath: installer.installedURL.path))
    }

    @Test("The samples folder is left out of device backups")
    func excludedFromBackup() throws {
        let installer = SampleDatabaseInstaller(bundledURL: bundled, directory: directory)
        try installer.installIfNeeded()

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
