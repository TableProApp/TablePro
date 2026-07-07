import Foundation
@testable import TablePro
import TableProImport
import Testing

@Suite("TeamCatalogPublisher")
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
        let envelope = try ConnectionImportDecoder.decodeData(data)
        #expect(envelope.credentials == nil)
        #expect(envelope.connections.first?.name == "Prod DB")
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
