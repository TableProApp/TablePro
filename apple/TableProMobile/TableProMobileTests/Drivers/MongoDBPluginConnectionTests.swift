import CLibMongoc
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

        let options = MongoDBSSLMapping.uriOptions(for: fixture.ssl, certificateKeyFile: file.path)

        #expect(options.filter { $0.key == "tlsCertificateKeyFile" } == [
            MongoDBURIOption(key: "tlsCertificateKeyFile", value: file.path)
        ])
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
        #expect(MongoDBSSLMapping.uriOptions(for: alone).contains(
            MongoDBURIOption(key: "tlsCertificateKeyFile", value: "/certs/client.pem")
        ))
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

// libmongoc decodes every option value and splits options on a raw `&`, so each test reads the built URI back with it.
struct MongoDBConnectionURITests {
    private func uri(
        host: String = "db.example.com",
        ssl: [MongoDBURIOption] = [],
        authSource: String = "admin",
        readPreference: String? = nil,
        writeConcern: String? = nil,
        authMechanism: String? = nil,
        replicaSet: String? = nil,
        extraParams: [String: String] = [:]
    ) -> String {
        MongoDBConnectionURI(
            useSrv: false, host: host, port: 27_017, user: "u", password: "p@ss:w/rd", database: "app",
            options: MongoDBConnectionURI.options(
                connectTimeout: MongoDBConnectTimeout(milliseconds: 5_000),
                authSource: authSource,
                ssl: ssl,
                readPreference: readPreference,
                writeConcern: writeConcern,
                authMechanism: authMechanism,
                replicaSet: replicaSet,
                extraParams: extraParams
            )
        ).text
    }

    private func parsed(_ text: String) throws -> OpaquePointer {
        var error = bson_error_t()
        let parsed = text.withCString { mongoc_uri_new_with_error($0, &error) }
        return try #require(parsed, "libmongoc refused \(text)")
    }

    private func option(_ uri: OpaquePointer, _ key: String) -> String? {
        mongoc_uri_get_option_as_utf8(uri, key, nil).map { String(cString: $0) }
    }

    @Test("A `&` or `=` in a field reaches libmongoc as part of its value, never as an option of its own")
    func fieldValuesCannotStartAnOption() throws {
        let caFile = "/Users/me/R&D/My Certs/c+a;b#1%.pem"
        let text = uri(
            ssl: MongoDBSSLMapping.uriOptions(for: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: caFile)),
            authSource: "adm&in",
            replicaSet: "rs&tlsAllowInvalidCertificates=true"
        )
        let parsed = try parsed(text)
        defer { mongoc_uri_destroy(parsed) }

        #expect(String(cString: mongoc_uri_get_replica_set(parsed)) == "rs&tlsAllowInvalidCertificates=true")
        #expect(String(cString: mongoc_uri_get_auth_source(parsed)) == "adm&in")
        #expect(option(parsed, MONGOC_URI_TLSCAFILE) == caFile)
        #expect(!mongoc_uri_has_option(parsed, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES))
        #expect(text.contains("replicaSet=rs%26tlsAllowInvalidCertificates%3Dtrue"))
    }

    // libmongoc refuses a read preference or mechanism it does not know, so these stay one value it can name.
    @Test("A read preference, write concern or mechanism is encoded whole")
    func dropdownValuesAreEncodedWhole() {
        let text = uri(
            readPreference: "secondary&appname=x",
            writeConcern: "majority&journal=false",
            authMechanism: "SCRAM-SHA-256&authSource=evil"
        )
        #expect(text.contains("readPreference=secondary%26appname%3Dx"))
        #expect(text.contains("w=majority%26journal%3Dfalse"))
        #expect(text.contains("authMechanism=SCRAM-SHA-256%26authSource%3Devil"))
        #expect(!text.contains("&appname="))
    }

    @Test("A typed parameter keeps its value whole, and a key with `&` in it cannot inject one")
    func typedParametersAreEncoded() throws {
        let parsed = try parsed(uri(extraParams: ["appname": "My App+1 & co/é", "tlsInsecure=true&x": "1"]))
        defer { mongoc_uri_destroy(parsed) }

        #expect(option(parsed, MONGOC_URI_APPNAME) == "My App+1 & co/é")
        #expect(!mongoc_uri_get_option_as_bool(parsed, MONGOC_URI_TLSINSECURE, false))
    }

    @Test("The Keychain's passphrase and session token replace any spelling a pasted string left")
    func keychainSecretsReplacePastedSpellings() {
        var params = [
            "sslClientCertificateKeyPassword": "old",
            "authmechanismproperties": "AWS_SESSION_TOKEN:old,SERVICE_NAME:mongodb",
            "retryWrites": "true"
        ]

        MongoDBConnectionURI.applySecrets(to: &params, keyPassphrase: "new", sessionToken: "FQoG")

        #expect(params == [
            "tlsCertificateKeyFilePassword": "new",
            "authMechanismProperties": "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:FQoG",
            "retryWrites": "true"
        ])
    }

    @Test("Without a Keychain secret the options are left as they are")
    func noKeychainSecretLeavesOptions() {
        var params = ["authMechanismProperties": "SERVICE_NAME:mongodb"]

        MongoDBConnectionURI.applySecrets(to: &params, keyPassphrase: nil, sessionToken: "")

        #expect(params == ["authMechanismProperties": "SERVICE_NAME:mongodb"])
    }

    @Test("A typed parameter named like a field's key in any case never overrides the field")
    func typedParameterKeysCompareWithoutCase() throws {
        let options = MongoDBConnectionURI.options(
            connectTimeout: MongoDBConnectTimeout(milliseconds: 5_000),
            authSource: "admin",
            ssl: [],
            readPreference: "nearest",
            writeConcern: nil,
            authMechanism: nil,
            replicaSet: "rs0",
            extraParams: ["REPLICASET": "other", "authsource": "evil", "ReadPreference": "primary", "w": "majority"]
        )
        let keys = options.map { $0.key.lowercased() }

        #expect(Set(keys).count == keys.count)
        #expect(options.contains(MongoDBURIOption(key: "replicaSet", value: "rs0")))
        #expect(options.contains(MongoDBURIOption(key: "authSource", value: "admin")))
        #expect(options.contains(MongoDBURIOption(key: "readPreference", value: "nearest")))
        #expect(options.contains(MongoDBURIOption(key: "w", value: "majority")))
    }

    @Test("With TLS on, the SSL mode owns certificate checking, and no typed TLS parameter conflicts with it")
    func typedTLSParametersYieldToTheSSLMode() throws {
        let typed = ["tlsInsecure": "true", "tlsDisableOCSPEndpointCheck": "true"]
        let required = MongoDBSSLMapping.uriOptions(for: SSLConfiguration(mode: .required))
        let relaxed = try parsed(uri(ssl: required, extraParams: typed))
        defer { mongoc_uri_destroy(relaxed) }
        #expect(mongoc_uri_get_option_as_bool(relaxed, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES, false))
        #expect(!mongoc_uri_has_option(relaxed, MONGOC_URI_TLSINSECURE))
        #expect(!mongoc_uri_has_option(relaxed, MONGOC_URI_TLSDISABLEOCSPENDPOINTCHECK))

        let verified = MongoDBSSLMapping.uriOptions(for: SSLConfiguration(mode: .verifyIdentity))
        let aliases = ["sslAllowInvalidCertificates": "true", "SSLAllowInvalidHostnames": "true", "ssl": "false"]
        let strict = try parsed(uri(ssl: verified, extraParams: typed.merging(aliases) { first, _ in first }))
        defer { mongoc_uri_destroy(strict) }
        #expect(!mongoc_uri_has_option(strict, MONGOC_URI_TLSINSECURE))
        #expect(!mongoc_uri_has_option(strict, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES))
        #expect(!mongoc_uri_has_option(strict, MONGOC_URI_TLSALLOWINVALIDHOSTNAMES))
        #expect(mongoc_uri_get_tls(strict))
        #expect(mongoc_uri_get_option_as_bool(strict, MONGOC_URI_TLSDISABLEOCSPENDPOINTCHECK, false))

        let plain = try parsed(uri(extraParams: ["tlsInsecure": "true"]))
        defer { mongoc_uri_destroy(plain) }
        #expect(mongoc_uri_get_option_as_bool(plain, MONGOC_URI_TLSINSECURE, false))
    }

    @Test("The user, password and database still read back as typed")
    func userInfoAndDatabaseRoundTrip() throws {
        let parsed = try parsed(uri())
        defer { mongoc_uri_destroy(parsed) }

        #expect(String(cString: mongoc_uri_get_username(parsed)) == "u")
        #expect(String(cString: mongoc_uri_get_password(parsed)) == "p@ss:w/rd")
        #expect(String(cString: mongoc_uri_get_database(parsed)) == "app")
    }

    @Test("A host list MongoDBHostList cannot read keeps a typed port out of the options")
    func unreadableHostListCannotStartTheOptions() {
        let text = uri(host: "a.example.com:1/?tlsInsecure=true,b.example.com")

        #expect(text.hasPrefix("mongodb://u:p%40ss%3Aw%2Frd@a.example.com:1%2F%3FtlsInsecure%3Dtrue,b.example.com:27017/app?"))
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
        MongoDBStatementGenerator(collectionName: "users", columns: ["_id", "name"], identityKinds: idKinds)
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

    @Test("Document text held both as an embedded document _id and as a string _id is refused")
    func documentAndTextIdentityIsRefused() {
        #expect(throws: PluginRowWriteRefusal.self) {
            try generator(idKinds: [.document, .string]).generateRowWrites(
                from: [update(id: #"{"a": 1}"#)], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
            )
        }
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

        let dated = MongoDBStatementGenerator(collectionName: "events", columns: ["_id", "name"], identityKinds: [.date])
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
