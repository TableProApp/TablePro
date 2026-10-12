import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct TeamCatalogPublisherTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("team-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Publishes one .tablepro file per connection")
    func publishesOneFilePerConnection() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let connections = [
            DatabaseConnection(name: "Prod DB"),
            DatabaseConnection(name: "Staging DB")
        ]
        let written = try TeamCatalogPublisher.publish(connections, to: folder)

        #expect(written.count == 2)
        for url in written {
            #expect(url.pathExtension == "tablepro")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Published file carries no credentials")
    func publishedFileHasNoCredentials() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let connection = DatabaseConnection(name: "Prod DB")
        let written = try TeamCatalogPublisher.publish([connection], to: folder)

        let data = try Data(contentsOf: try #require(written.first))
        let bundle = try ConnectionBundleCodec.decode(data)
        #expect(bundle.credentials.isEmpty)
        #expect(bundle.connections.first?.settings.name == "Prod DB")
    }

    @Test("Published file carries no saved queries or passwords")
    func publishedFileHasNoSavedQueries() async throws {
        let folder = try makeTempDirectory()
        let library = try ImportLibraryFixture()
        defer {
            try? FileManager.default.removeItem(at: folder)
            library.cleanUp()
        }
        let connection = DatabaseConnection(name: "Prod DB")
        #expect(library.connections.savePassword("hunter2", for: connection.id))
        _ = await library.favorites.addFavorite(
            SQLFavorite(name: "Daily", query: "select 1", connectionId: connection.id)
        )

        let written = try TeamCatalogPublisher.publish([connection], to: folder, exporter: library.exporter)

        let data = try Data(contentsOf: try #require(written.first))
        let bundle = try ConnectionBundleCodec.decode(data)
        #expect(bundle.savedQueries.isEmpty)
        #expect(bundle.queryFolders.isEmpty)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("hunter2"))
    }

    @Test("Published file cannot carry a command password source (RCE guard)")
    func publishStripsPasswordSource() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let connection = DatabaseConnection(name: "Prod DB", passwordSource: .command(shell: "echo PWNED"))
        let written = try TeamCatalogPublisher.publish([connection], to: folder)

        let data = try Data(contentsOf: try #require(written.first))
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.contains("PWNED"))
        #expect(!raw.contains("passwordSource"))
    }

    @Test("Filename is filesystem-safe and keyed by connection id")
    func filenameIsFilesystemSafeAndStable() {
        let connection = DatabaseConnection(name: "Prod / DB: primary")
        let name = TeamCatalogPublisher.filename(for: connection)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".tablepro"))
        #expect(name.contains(String(connection.id.uuidString.prefix(8))))
    }

    @Test("Republishing the same connection overwrites a single file")
    func republishOverwritesSameFile() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let connection = DatabaseConnection(name: "Prod DB")
        _ = try TeamCatalogPublisher.publish([connection], to: folder)
        _ = try TeamCatalogPublisher.publish([connection], to: folder)

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".tablepro") }
        #expect(contents.count == 1)
    }

    @Test("Republishing a renamed connection replaces its file and leaves other connections' files alone")
    func republishRenamedConnectionReplacesItsFile() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let other = DatabaseConnection(name: "Staging DB")
        var renamed = DatabaseConnection(name: "A")
        _ = try TeamCatalogPublisher.publish([other, renamed], to: folder)
        renamed.name = "B"
        _ = try TeamCatalogPublisher.publish([renamed], to: folder)

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".tablepro") }
            .sorted()
        #expect(contents == [TeamCatalogPublisher.filename(for: renamed), TeamCatalogPublisher.filename(for: other)])

        let data = try Data(contentsOf: folder.appendingPathComponent(TeamCatalogPublisher.filename(for: renamed)))
        #expect(try ConnectionBundleCodec.decode(data).connections.map(\.settings.name) == ["B"])
    }

    @Test("Republishing never removes a folder that matches a connection's file name")
    func republishLeavesMatchingFolderAlone() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        var renamed = DatabaseConnection(name: "A")
        let lookalike = folder.appendingPathComponent("Archive-\(renamed.id.uuidString.prefix(8)).tablepro")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: false)
        renamed.name = "B"
        _ = try TeamCatalogPublisher.publish([renamed], to: folder)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: lookalike.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Republishing a connection renamed only in case keeps its file")
    func republishCaseOnlyRenameKeepsItsFile() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        var renamed = DatabaseConnection(name: "prod")
        _ = try TeamCatalogPublisher.publish([renamed], to: folder)
        renamed.name = "Prod"
        let written = try TeamCatalogPublisher.publish([renamed], to: folder)

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".tablepro") }
        #expect(contents.count == 1)
        let data = try Data(contentsOf: try #require(written.first))
        #expect(try ConnectionBundleCodec.decode(data).connections.map(\.settings.name) == ["Prod"])
    }

    @Test("A publish whose earlier file cannot be removed still writes every connection")
    func publishSurvivesAnEarlierFileItCannotRemove() throws {
        let folder = try makeTempDirectory()
        defer {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            }
            try? FileManager.default.removeItem(at: folder)
        }

        var renamed = DatabaseConnection(name: "A")
        let earlierFile = try #require(try TeamCatalogPublisher.publish([renamed], to: folder).first)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: earlierFile.path)
        renamed.name = "B"
        let other = DatabaseConnection(name: "Staging DB")

        let written = try TeamCatalogPublisher.publish([renamed, other], to: folder)

        let expectedNames = [TeamCatalogPublisher.filename(for: renamed), TeamCatalogPublisher.filename(for: other)]
        #expect(written.map(\.lastPathComponent) == expectedNames)
        for name in expectedNames {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
    }

    @Test("Throws when there are no connections")
    func throwsOnEmpty() throws {
        let folder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: TeamCatalogError.self) {
            _ = try TeamCatalogPublisher.publish([], to: folder)
        }
    }

    @Test("Throws when the destination is not a folder")
    func throwsOnNonDirectory() {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(throws: TeamCatalogError.self) {
            _ = try TeamCatalogPublisher.publish([DatabaseConnection(name: "X")], to: bogus)
        }
    }
}
