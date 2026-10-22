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

struct MongoSessionKillsTests {
    @Test("A session is killed once until that kill ends, so a resent Stop queues no second one")
    func killsCoalescePerSession() {
        var kills = MongoSessionKills()
        let first = kills.begin("a")
        let resent = kills.begin("a")
        let other = kills.begin("b")
        kills.end("a")
        let afterEnd = kills.begin("a")

        #expect(first)
        #expect(!resent)
        #expect(other)
        #expect(afterEnd)
    }
}

struct MongoDBHostListTests {
    @Test("Each host is written with its port once", arguments: [
        ("localhost", "localhost:27017"),
        ("db1.internal:27018, db2.internal", "db1.internal:27018,db2.internal:27017"),
        ("[::1]:27018,[fe80::1]", "[::1]:27018,[fe80::1]:27017"),
        ("::1", "[::1]:27017")
    ])
    func hostsCarryOnePort(raw: String, expected: String) {
        #expect(MongoDBHostList.uriHosts(raw, defaultPort: 27_017) == expected)
    }

    @Test("An entry with a port that is not a number is not rewritten", arguments: ["db1:abc", "db1:70000", "[::1]x"])
    func unreadableEntryIsLeftAlone(raw: String) {
        #expect(MongoDBHostList.uriHosts(raw, defaultPort: 27_017) == nil)
    }
}

struct MongoDBAmbiguousIdentityTests {
    private func generator(idKinds: Set<BsonValueKind>) -> MongoDBStatementGenerator {
        MongoDBStatementGenerator(
            collectionName: "users",
            columns: ["_id", "name"],
            fieldKinds: MongoDBFieldKinds(["_id": idKinds])
        )
    }

    private func update(id: String) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "name", .text("old"), .text("new"))],
            originalRow: [.text(id), .text("old")]
        )
    }

    @Test("An _id held both as an ObjectId and as text with the same hex is refused, never guessed")
    func ambiguousIdentityIsRefused() {
        let hex = "64b7f0c2a1b2c3d4e5f60718"
        #expect(throws: PluginRowWriteRefusal.self) {
            try generator(idKinds: [.objectId, .string]).generateRowWrites(
                from: [update(id: hex)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
    }

    @Test("An _id held as a number and as text with the same digits is refused too")
    func numberAndTextIdentityIsRefused() {
        #expect(throws: PluginRowWriteRefusal.self) {
            try generator(idKinds: [.int32, .string]).generateRowWrites(
                from: [update(id: "1")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
    }

    @Test("Mixed _id kinds type the text as the one kind it can be: text, or a number of any width")
    func mixedKindsTypeTheText() throws {
        let text = try #require(try generator(idKinds: [.objectId, .string]).generateRowWrites(
            from: [update(id: "5")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first)
        let number = try #require(try generator(idKinds: [.int32, .int64]).generateRowWrites(
            from: [update(id: "5")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first)

        #expect(text.statement.contains(#"{"_id": "5"}"#))
        #expect(!number.statement.contains(#""5""#))
    }

    @Test("A number past 2^53 names the integer, never the double it rounds to")
    func largeIntegerKeepsItsValue() throws {
        for idKinds: Set<BsonValueKind> in [[.int32, .double], [.int64, .double]] {
            let write = try #require(try generator(idKinds: idKinds).generateRowWrites(
                from: [update(id: "9007199254740993")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            ).first)

            #expect(write.statement.contains(#"{"_id": {"$numberLong": "9007199254740993"}}"#))
            #expect(!write.statement.contains("$numberDouble"))
        }
    }

    @Test("A fraction held as a double and as a decimal names two values, so it is refused")
    func doubleAndDecimalFractionIsRefused() {
        #expect(throws: PluginRowWriteRefusal.self) {
            try generator(idKinds: [.double, .decimal128]).generateRowWrites(
                from: [update(id: "0.1")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
    }

    @Test("An integer held as a double and as a decimal is one value")
    func doubleAndDecimalIntegerWrites() throws {
        let write = try #require(try generator(idKinds: [.double, .decimal128]).generateRowWrites(
            from: [update(id: "5")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first)
        #expect(write.statement.contains(#"{"_id": {"$numberDecimal": "5"}}"#))
    }

    @Test("Every read holding one _id kind types the text by it, not by its shape")
    func singleHeldKindTypesTheText() throws {
        let hex = "64b7f0c2a1b2c3d4e5f60718"
        let write = try #require(try generator(idKinds: [.string]).generateRowWrites(
            from: [update(id: hex)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first)
        #expect(write.statement.contains(#"{"_id": "\#(hex)"}"#))
    }

    @Test("A date _id keeps its milliseconds from the cell to the filter")
    func dateIdentityKeepsMilliseconds() throws {
        let stored = Date(timeIntervalSince1970: 1_704_110_400.5)
        let text = try #require(BsonDocumentFlattener.stringValue(for: stored, representation: .unspecified))
        #expect(text == "2024-01-01T12:00:00.500Z")
        #expect(BsonDocumentFlattener.stringValue(
            for: Date(timeIntervalSince1970: 1_704_110_400), representation: .unspecified
        ) == "2024-01-01T12:00:00Z")

        let dated = MongoDBStatementGenerator(collectionName: "events", columns: ["_id", "name"], identityKind: .date)
        let write = try #require(try dated.generateRowWrites(
            from: [update(id: text)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).first)
        #expect(write.statement.contains(#""$numberLong": "1704110400500""#))
    }

    @Test("A date at either end of the BSON range still shows")
    func extremeDatesShow() {
        for milliseconds in [Int64.max, Int64.min] {
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            #expect(BsonDocumentFlattener.stringValue(for: date, representation: .unspecified) != nil)
        }
    }

    @Test("Text that cannot be an ObjectId, or a collection of one _id kind, still writes")
    func unambiguousIdentityWrites() throws {
        let mixed = try generator(idKinds: [.objectId, .string]).generateRowWrites(
            from: [update(id: "user-42")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let uniform = try generator(idKinds: [.objectId]).generateRowWrites(
            from: [update(id: "64b7f0c2a1b2c3d4e5f60718")], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(mixed.count == 1)
        #expect(uniform.count == 1)
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
