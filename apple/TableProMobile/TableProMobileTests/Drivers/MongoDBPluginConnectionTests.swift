import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoDBPluginConnectionTests {
    private static let certificate = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
    private static let key = "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n"

    // libmongoc refuses MONGODB-X509 with any other authSource: GSSAPI and X509 require "$external" authSource.
    @Test("X.509 and AWS with a blank Auth Database authenticate against $external", arguments: [
        "MONGODB-X509", "mongodb-x509", "MONGODB-AWS", "MongoDB-AWS"
    ])
    func externalMechanismsDefaultToExternal(mechanism: String) {
        for explicit in [nil, ""] as [String?] {
            let resolved = MongoDBAuthSourceResolver.resolve(
                explicitAuthSource: explicit, configuredDatabase: "app", useSrv: false, authMechanism: mechanism
            )
            #expect(resolved == "$external")
        }
    }

    @Test("An Auth Database the user typed wins over the mechanism's default")
    func explicitAuthSourceWins() {
        let resolved = MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: "certs", configuredDatabase: "app", useSrv: false, authMechanism: "MONGODB-X509"
        )
        #expect(resolved == "certs")
    }

    @Test("SCRAM keeps the database, or admin over SRV or without a database", arguments: [nil, "SCRAM-SHA-256"] as [String?])
    func scramKeepsDatabaseOrAdmin(mechanism: String?) {
        #expect(MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: nil, configuredDatabase: "app", useSrv: false, authMechanism: mechanism
        ) == "app")
        #expect(MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: nil, configuredDatabase: "app", useSrv: true, authMechanism: mechanism
        ) == "admin")
        #expect(MongoDBAuthSourceResolver.resolve(
            explicitAuthSource: "", configuredDatabase: "", useSrv: false, authMechanism: mechanism
        ) == "admin")
    }

    @Test("The combined PEM is the certificate, a newline only where it has none, then the key")
    func combinedPEMJoinsCertificateThenKey() {
        #expect(MongoDBClientCertificateFile.combinedPEM(certificate: "CERT", key: "KEY\n") == "CERT\nKEY\n")
        #expect(MongoDBClientCertificateFile.combinedPEM(certificate: "CERT\n", key: "KEY\n") == "CERT\nKEY\n")
        #expect(MongoDBClientCertificateFile.combinedPEM(certificate: "CERT\r\n", key: "KEY") == "CERT\r\nKEY")
    }

    @Test("A separate key is joined into a file only the owner can read, and removing it deletes it")
    func joinedFileIsPrivateAndRemovable() throws {
        let fixture = try KeyPairFiles(certificate: Self.certificate, key: Self.key)
        defer { fixture.remove() }

        let file = try #require(try MongoDBClientCertificateFile.joining(fixture.ssl))
        defer { file.remove() }

        let fileManager = FileManager.default
        let directory = MongoDBClientCertificateFile.directory.path
        #expect(file.path.hasPrefix(directory))
        let directoryMode = try fileManager.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        let fileMode = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(try String(contentsOfFile: file.path, encoding: .utf8) == Self.certificate + "\n" + Self.key)

        file.remove()
        #expect(!fileManager.fileExists(atPath: file.path))
    }

    @Test("Each connection gets its own joined file")
    func joinedFilesAreUnique() throws {
        let fixture = try KeyPairFiles(certificate: Self.certificate, key: Self.key)
        defer { fixture.remove() }

        let first = try #require(try MongoDBClientCertificateFile.joining(fixture.ssl))
        defer { first.remove() }
        let second = try #require(try MongoDBClientCertificateFile.joining(fixture.ssl))
        defer { second.remove() }

        #expect(first.path != second.path)
    }

    @Test("The URI names the joined file as the certificate key file, and nothing else")
    func uriParametersNameTheJoinedFile() throws {
        let fixture = try KeyPairFiles(certificate: Self.certificate, key: Self.key)
        defer { fixture.remove() }
        let file = try #require(try MongoDBClientCertificateFile.joining(fixture.ssl))
        defer { file.remove() }

        let parameters = MongoDBSSLMapping.uriParameters(for: fixture.ssl, certificateKeyFile: file.path)

        let encoded = try #require(file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        #expect(parameters.filter { $0.hasPrefix("tlsCertificateKeyFile=") } == ["tlsCertificateKeyFile=\(encoded)"])
    }

    @Test("A certificate alone, or a key at the certificate's own path, is passed as it is")
    func certificateWithoutSeparateKeyIsNotJoined() throws {
        let alone = SSLConfiguration(mode: .required, clientCertificatePath: "/certs/client.pem")
        let samePath = SSLConfiguration(
            mode: .required, clientCertificatePath: "/certs/client.pem", clientKeyPath: "/certs/client.pem"
        )
        let disabled = SSLConfiguration(
            mode: .disabled, clientCertificatePath: "/certs/client.pem", clientKeyPath: "/certs/client.key"
        )

        for ssl in [alone, samePath, disabled] {
            #expect(try MongoDBClientCertificateFile.joining(ssl)?.path == nil)
        }
        #expect(MongoDBSSLMapping.uriParameters(for: alone).contains("tlsCertificateKeyFile=/certs/client.pem"))
    }

    @Test("A key file that cannot be read fails with its path")
    func unreadableKeyFails() throws {
        let fixture = try KeyPairFiles(certificate: Self.certificate, key: Self.key)
        defer { fixture.remove() }
        let missing = fixture.directory.appendingPathComponent("missing.key").path
        let ssl = SSLConfiguration(
            mode: .required, clientCertificatePath: fixture.ssl.clientCertificatePath, clientKeyPath: missing
        )

        let error = try #require(throws: MongoDBError.self) {
            try MongoDBClientCertificateFile.joining(ssl)
        }
        #expect(error.message.contains(missing))
    }
}

private struct KeyPairFiles {
    let directory: URL
    let ssl: SSLConfiguration

    init(certificate: String, key: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MongoDBPluginConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificateURL = directory.appendingPathComponent("client.crt")
        let keyURL = directory.appendingPathComponent("client.key")
        try Data(certificate.utf8).write(to: certificateURL)
        try Data(key.utf8).write(to: keyURL)
        ssl = SSLConfiguration(mode: .required, clientCertificatePath: certificateURL.path, clientKeyPath: keyURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
