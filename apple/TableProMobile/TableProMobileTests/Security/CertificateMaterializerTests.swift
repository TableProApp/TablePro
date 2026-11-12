import Foundation
@testable import TableProMobile
import TableProDatabase
import Testing

struct CertificateMaterializerTests {
    private let root: URL
    private let certificates = InMemoryCertificateStore()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("ios-certificates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var materializer: CertificateMaterializer {
        CertificateMaterializer(store: certificates, root: root)
    }

    private func folder(_ connectionId: UUID) -> URL {
        root.appendingPathComponent(connectionId.uuidString, isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("Deleting a connection removes the client key a connect wrote to disk")
    func deleteRemovesTheKeyFile() throws {
        let connectionId = UUID()
        try certificates.store("key", role: .clientKey, for: connectionId)
        let written = try #require(try materializer.materialize(for: connectionId).clientKeyPath)
        #expect(exists(URL(filePath: written)))

        let secrets = ConnectionSecrets(
            secureStore: MockSecureStore(),
            certificateStore: certificates,
            bookmarkStore: FileBookmarkStore(suiteName: "com.TablePro.tests.CertificateMaterializer.\(UUID().uuidString)"),
            materializer: materializer
        )
        secrets.delete(for: connectionId)

        #expect(!exists(URL(filePath: written)))
        #expect(!exists(folder(connectionId)))
    }

    @Test("A certificate removed from the connection loses its file on the next connect")
    func removedRoleLosesItsFile() throws {
        let connectionId = UUID()
        try certificates.store("ca", role: .certificateAuthority, for: connectionId)
        try certificates.store("key", role: .clientKey, for: connectionId)
        let first = try materializer.materialize(for: connectionId)
        let keyPath = try #require(first.clientKeyPath)

        certificates.delete(role: .clientKey, for: connectionId)
        let second = try materializer.materialize(for: connectionId)

        #expect(second.clientKeyPath == nil)
        #expect(second.caCertificatePath != nil)
        #expect(!exists(URL(filePath: keyPath)))
    }

    @Test("The launch sweep removes the folders of connections that are gone and keeps the rest")
    func sweepKeepsKnownConnections() throws {
        let kept = UUID()
        let gone = UUID()
        for connectionId in [kept, gone] {
            try certificates.store("key", role: .clientKey, for: connectionId)
            _ = try materializer.materialize(for: connectionId)
        }
        let unrelated = root.appendingPathComponent("not-a-connection", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        materializer.releaseAll(except: [kept])

        #expect(exists(folder(kept)))
        #expect(!exists(folder(gone)))
        #expect(exists(unrelated))
    }
}
