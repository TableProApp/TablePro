//
//  LibPQConnectionStringTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQConnectionStringTests {
    private func build(
        user: String = "postgres",
        password: String? = "hunter2",
        sslConfig: SSLConfiguration = SSLConfiguration(),
        options: String? = nil,
        applicationName: String? = nil,
        connectTimeoutSeconds: Int? = nil,
        systemTrustAnchorsPath: String? = nil
    ) throws -> String {
        try LibPQConnectionString.build(
            host: "db.example.com",
            port: 5_432,
            user: user,
            password: password,
            database: "app",
            sslConfig: sslConfig,
            options: options,
            applicationName: applicationName,
            connectTimeoutSeconds: connectTimeoutSeconds,
            systemTrustAnchorsPath: systemTrustAnchorsPath
        )
    }

    @Test("The base parameters are always present")
    func baseParameters() throws {
        let conninfo = try build()

        #expect(conninfo.contains("host='db.example.com'"))
        #expect(conninfo.contains("port='5432'"))
        #expect(conninfo.contains("dbname='app'"))
        #expect(conninfo.contains("user='postgres'"))
        #expect(conninfo.contains("password='hunter2'"))
        #expect(conninfo.contains("sslmode='disable'"))
    }

    @Test("The remaining budget reaches libpq's native connection setting")
    func connectTimeoutReachesConnectionString() throws {
        let timeout = LibPQConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "4201"])

        #expect(timeout.nativeSeconds == 5)
        #expect(try build(connectTimeoutSeconds: timeout.nativeSeconds).contains("connect_timeout='5'"))
    }

    @Test("The compatibility timeout is clamped before reaching libpq")
    func connectTimeoutFallbackClamps() {
        #expect(LibPQConnectTimeout(additionalFields: ["connectTimeoutSeconds": "0"]).milliseconds == 1)
        #expect(
            LibPQConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int64.min)]).milliseconds == 1
        )
        #expect(
            LibPQConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "999999999"]).milliseconds
                == LibPQConnectTimeout.maximumMilliseconds
        )
    }

    @Test("TCP and bootstrap probes consume one absolute libpq deadline")
    func connectDeadlineShrinksAcrossPhases() {
        let deadline = LibPQConnectDeadline(
            timeout: LibPQConnectTimeout(milliseconds: 4_200),
            nowMicroseconds: 1_000_000
        )

        #expect(deadline.remainingMicroseconds(nowMicroseconds: 2_250_000) == 2_950_000)
        #expect(
            deadline.nextPollDeadline(nowMicroseconds: 2_250_000, maximumSliceMicroseconds: 100_000)
                == 2_350_000
        )
        #expect(deadline.remainingMicroseconds(nowMicroseconds: 5_200_000) == nil)
        #expect(
            deadline.nextPollDeadline(nowMicroseconds: 5_200_000, maximumSliceMicroseconds: 100_000) == nil
        )
    }

    private func buildKerberos(host: String, serverName: String? = nil) throws -> String {
        try LibPQConnectionString.build(
            host: host,
            port: 5_432,
            user: "alice",
            password: nil,
            database: "app",
            sslConfig: SSLConfiguration(),
            options: nil,
            kerberos: LibPQKerberosSignIn(gssEncryptionMode: "require", cachePath: nil),
            serverName: serverName
        )
    }

    private func build(dialing host: String, serverName: String?, mode: SSLMode = .verifyIdentity) throws -> String {
        try LibPQConnectionString.build(
            host: host,
            port: 54_321,
            user: "postgres",
            password: "hunter2",
            database: "app",
            sslConfig: SSLConfiguration(mode: mode, caCertificatePath: "/ca.pem"),
            options: nil,
            serverName: serverName
        )
    }

    private func build(from config: DriverConnectionConfig, kerberos: LibPQKerberosSignIn? = nil) throws -> String {
        try LibPQConnectionString.build(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            sslConfig: config.ssl,
            options: nil,
            kerberos: kerberos,
            serverName: config.tunneledServerName
        )
    }

    @Test("Any other sign-in never tries GSS encryption and refuses GSS authentication")
    func otherSignInsStayOffGSS() throws {
        let conninfo = try build()

        #expect(conninfo.contains("gssencmode='disable'"))
        #expect(conninfo.contains("require_auth='!gss'"))
    }

    @Test("A Kerberos sign-in passes its GSS Encryption mode and allows GSS authentication")
    func kerberosPassesGSSEncryption() throws {
        let conninfo = try buildKerberos(host: "db.corp.example.com")

        #expect(conninfo.contains("gssencmode='require'"))
        #expect(!conninfo.contains("require_auth"))
        #expect(!conninfo.contains("password="))
        #expect(conninfo.hasPrefix("host='db.corp.example.com' port="))
    }

    @Test("Behind a tunnel, GSS names the server's own host while libpq dials the tunnel")
    func kerberosThroughATunnel() throws {
        let conninfo = try buildKerberos(host: "127.0.0.1", serverName: "db.corp.example.com")

        #expect(conninfo.hasPrefix("host='db.corp.example.com' hostaddr='127.0.0.1' port="))
    }

    @Test("A tunnel host that is not an address keeps the plain host", arguments: ["localhost", "/tmp"])
    func kerberosWithoutAnAddressKeepsTheHost(host: String) throws {
        let conninfo = try buildKerberos(host: host, serverName: "db.corp.example.com")

        #expect(!conninfo.contains("db.corp.example.com"))
    }

    @Test(
        "Verify Identity through a forward checks the server's name while libpq dials the forward",
        arguments: ["127.0.0.1", "::1"]
    )
    func verifyFullThroughAForward(dial: String) throws {
        let conninfo = try build(dialing: dial, serverName: "db.example.com")

        #expect(conninfo.hasPrefix("host='db.example.com' hostaddr='\(dial)' port='54321'"))
        #expect(conninfo.contains("sslmode='verify-full'"))
        #expect(conninfo.contains("sslrootcert='/ca.pem'"))
    }

    @Test("Verify CA through a forward keeps the CA and still dials the forward")
    func verifyCAThroughAForward() throws {
        let conninfo = try build(dialing: "127.0.0.1", serverName: "db.example.com", mode: .verifyCa)

        #expect(conninfo.hasPrefix("host='db.example.com' hostaddr='127.0.0.1' port='54321'"))
        #expect(conninfo.contains("sslmode='verify-ca'"))
        #expect(conninfo.contains("sslrootcert='/ca.pem'"))
    }

    @Test(
        "A stored pre-tunnel host names the server only when libpq dials a tunnel's forward",
        arguments: [
            ("127.0.0.1", "host='db.example.com' hostaddr='127.0.0.1' port="),
            ("10.0.0.5", "host='10.0.0.5' port=")
        ]
    )
    func storedPreTunnelHostOnlyThroughAForward(dial: String, expectedPrefix: String) throws {
        let config = DriverConnectionConfig(
            host: dial,
            port: 5_432,
            username: "postgres",
            password: "",
            database: "app",
            ssl: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/ca.pem"),
            additionalFields: ["preTunnelHost": "db.example.com"]
        )
        let kerberos = LibPQKerberosSignIn(gssEncryptionMode: "prefer", cachePath: nil)

        #expect(try build(from: config).hasPrefix(expectedPrefix))
        #expect(try build(from: config, kerberos: kerberos).hasPrefix(expectedPrefix))
    }

    @Test("Every connection names a password file that cannot exist, so libpq never reads ~/.pgpass on its own")
    func everyConnectionSkipsLibpqPassfile() throws {
        let conninfos = [
            try build(),
            try build(password: nil),
            try build(user: "", password: ""),
            try buildKerberos(host: "db.corp.example.com"),
            try build(dialing: "127.0.0.1", serverName: "db.example.com"),
            try LibPQConnectionString.build(
                host: "/tmp",
                port: 5_432,
                user: "postgres",
                password: nil,
                database: "app",
                sslConfig: SSLConfiguration(),
                options: nil
            )
        ]

        for conninfo in conninfos {
            #expect(conninfo.contains("passfile='/dev/null/pgpass'"))
        }
    }

    @Test("The session is pinned to UTF8 in the startup packet, so RESET ALL and DISCARD ALL keep it")
    func pinsClientEncoding() throws {
        #expect(try build().contains("client_encoding='UTF8'"))
    }

    @Test("Connection options still reach the server, after the pinned encoding")
    func optionsFollowTheEncoding() throws {
        let conninfo = try build(options: "--cluster=my-cluster -c search_path=app")

        #expect(conninfo.hasSuffix("client_encoding='UTF8' options='--cluster=my-cluster -c search_path=app'"))
    }

    @Test("A client_encoding in the connection options rides along in options, where the server applies it first")
    func clientEncodingInOptionsStaysInOptions() throws {
        let conninfo = try build(options: "-c client_encoding=LATIN1")

        #expect(conninfo.contains("client_encoding='UTF8'"))
        #expect(conninfo.contains("options='-c client_encoding=LATIN1'"))
    }

    @Test("An empty user, password or options is left out")
    func emptyValuesAreOmitted() throws {
        let conninfo = try build(user: "", password: "", options: "")

        #expect(!conninfo.contains("user="))
        #expect(!conninfo.contains("password="))
        #expect(!conninfo.contains("options="))
        #expect(conninfo.contains("client_encoding='UTF8'"))
    }

    @Test("A CA certificate is sent only when the mode verifies it")
    func caOnlyWhenVerifying() throws {
        let requiring = try build(sslConfig: SSLConfiguration(mode: .required, caCertificatePath: "/ca.pem"))
        #expect(!requiring.contains("sslrootcert"))

        let verifying = try build(sslConfig: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/ca.pem"))
        #expect(verifying.contains("sslmode='verify-ca'"))
        #expect(verifying.contains("sslrootcert='/ca.pem'"))
    }

    @Test("Verify Identity with no CA file checks the server against this Mac's trusted roots")
    func verifyIdentityWithoutACAUsesTheSystemAnchors() throws {
        let conninfo = try build(
            sslConfig: SSLConfiguration(mode: .verifyIdentity),
            systemTrustAnchorsPath: "/tmp/roots.pem"
        )

        #expect(conninfo.contains("sslmode='verify-full'"))
        #expect(conninfo.contains("sslrootcert='/tmp/roots.pem'"))
    }

    @Test("A chosen CA file wins over this Mac's trusted roots")
    func aCAFileWinsOverTheSystemAnchors() throws {
        let conninfo = try build(
            sslConfig: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/ca.pem"),
            systemTrustAnchorsPath: "/tmp/roots.pem"
        )

        #expect(conninfo.contains("sslrootcert='/ca.pem'"))
        #expect(!conninfo.contains("/tmp/roots.pem"))
    }

    @Test("Verify CA never checks the server against this Mac's trusted roots")
    func verifyCAWithoutACAGetsNoSystemAnchors() throws {
        let conninfo = try build(sslConfig: SSLConfiguration(mode: .verifyCa), systemTrustAnchorsPath: "/tmp/roots.pem")

        #expect(conninfo.contains("sslmode='verify-ca'"))
        #expect(!conninfo.contains("sslrootcert"))
    }

    @Test("A mode that checks no certificate gets no root file", arguments: [SSLMode.disabled, .preferred, .required])
    func requiredAndPreferredNeverGetSystemAnchors(mode: SSLMode) throws {
        let conninfo = try build(sslConfig: SSLConfiguration(mode: mode), systemTrustAnchorsPath: "/tmp/roots.pem")

        #expect(!conninfo.contains("sslrootcert"))
    }

    @Test("The roots come from the CA file, then libpq's own root.crt, then this Mac's trusted roots")
    func rootCertificateSourceOrder() {
        let home = ["HOME": "/Users/test"]
        let rootCrt = "/Users/test/.postgresql/root.crt"
        func source(
            _ mode: SSLMode,
            ca: String = "",
            host: String = "db.example.com",
            rootCrtExists: Bool = false
        ) -> LibPQRootCertificateSource? {
            LibPQConnectionString.rootCertificateSource(
                for: SSLConfiguration(mode: mode, caCertificatePath: ca),
                host: host,
                environment: home,
                fileExists: { rootCrtExists && $0 == rootCrt }
            )
        }

        #expect(source(.verifyIdentity, ca: "/ca.pem", rootCrtExists: true) == .caFile("/ca.pem"))
        #expect(source(.verifyCa, ca: "/ca.pem") == .caFile("/ca.pem"))
        #expect(source(.verifyIdentity, rootCrtExists: true) == .libpqDefault)
        #expect(source(.verifyIdentity) == .systemTrustAnchors)
        #expect(source(.verifyIdentity, host: "/tmp") == .libpqDefault)
        #expect(source(.verifyCa) == .libpqDefault)
        #expect(source(.required) == nil)
        #expect(source(.preferred) == nil)
        #expect(source(.disabled) == nil)
    }

    @Test("A PGSSLROOTCERT the user set, or an empty host, leaves the roots to libpq")
    func namedRootFileAndDefaultSocketStayWithLibpq() {
        let config = SSLConfiguration(mode: .verifyIdentity)
        #expect(LibPQConnectionString.rootCertificateSource(
            for: config, host: "db.example.com", environment: ["HOME": "/Users/test", "PGSSLROOTCERT": "/etc/corp-ca.pem"],
            fileExists: { _ in false }
        ) == .libpqDefault)
        #expect(LibPQConnectionString.rootCertificateSource(
            for: config, host: "", environment: ["HOME": "/Users/test"], fileExists: { _ in false }
        ) == .libpqDefault)
        #expect(LibPQConnectionString.rootCertificateSource(
            for: config, host: "db.example.com", environment: ["HOME": "/Users/test", "PGSSLROOTCERT": ""],
            fileExists: { _ in false }
        ) == .systemTrustAnchors)
    }

    @Test("libpq's own root file is found under HOME, and under the account's home when HOME is unset or empty")
    func defaultRootCertificateFollowsHome() {
        let fallback = NSHomeDirectory() + "/.postgresql/root.crt"

        #expect(LibPQConnectionString.defaultRootCertificatePath(environment: ["HOME": "/Users/test"])
            == "/Users/test/.postgresql/root.crt")
        #expect(LibPQConnectionString.defaultRootCertificatePath(environment: ["HOME": ""]) == fallback)
        #expect(LibPQConnectionString.defaultRootCertificatePath(environment: [:]) == fallback)
    }

    @Test("A client certificate and key reach libpq as sslcert and sslkey")
    func clientCertificateIsSent() throws {
        let conninfo = try build(sslConfig: SSLConfiguration(
            mode: .required,
            clientCertificatePath: "/client.pem",
            clientKeyPath: "/client.key"
        ))

        #expect(conninfo.contains("sslcert='/client.pem'"))
        #expect(conninfo.contains("sslkey='/client.key'"))
    }

    @Test("Quotes and backslashes in values are escaped")
    func escapesValues() throws {
        let conninfo = try build(user: "o'brien", password: "back\\slash", options: "-c application_name='x'")

        #expect(conninfo.contains("user='o\\'brien'"))
        #expect(conninfo.contains("password='back\\\\slash'"))
        #expect(conninfo.contains("options='-c application_name=\\'x\\''"))
    }

    @Test("A quote a combining mark follows is still escaped")
    func escapesAQuoteBeforeACombiningMark() throws {
        #expect(try build(user: "a'\u{301} host=evil").contains("user='a\\'\u{301} host=evil'"))
    }

    @Test("A line break stays inside the quotes, where libpq reads it as data")
    func keepsALineBreakAsData() throws {
        #expect(try build(password: "a\nhost=evil").contains("password='a\nhost=evil'"))
    }

    @Test(
        "A NUL in any setting fails the connect and names the setting, instead of libpq reading a cut string",
        arguments: ["host", "dbname", "user", "password", "options", "sslcert"]
    )
    func refusesANULCharacter(keyword: String) {
        let value = "a\u{0}b"
        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQConnectionString.build(
                host: keyword == "host" ? value : "db.example.com",
                port: 5_432,
                user: keyword == "user" ? value : "postgres",
                password: keyword == "password" ? value : "hunter2",
                database: keyword == "dbname" ? value : "app",
                sslConfig: SSLConfiguration(
                    mode: .required,
                    clientCertificatePath: keyword == "sslcert" ? value : ""
                ),
                options: keyword == "options" ? value : nil
            )
        }
        #expect(error?.message.contains(keyword) == true)
    }

    @Test("The application name reaches libpq as a fallback, ahead of the connection options")
    func sendsFallbackApplicationName() throws {
        let conninfo = try build(options: "-c search_path=app", applicationName: "TablePro Metadata")

        #expect(conninfo.hasSuffix(
            "client_encoding='UTF8' fallback_application_name='TablePro Metadata' options='-c search_path=app'"
        ))
        #expect(!conninfo.contains(" application_name="))
    }

    @Test("No application name, or an empty one, sends no application name keyword")
    func omitsMissingApplicationName() throws {
        #expect(try !build().contains("application_name"))
        #expect(try !build(applicationName: "").contains("application_name"))
    }

    // Measured on libpq 17: a fallback name replaces an `application_name` set in `options`, so it
    // has to stay out whenever the user named the session there, in any of the server's spellings.
    @Test(
        "A name the user gives the session in the connection options keeps the fallback out",
        arguments: [
            "-c application_name=reporting",
            "-capplication_name=reporting",
            "--application_name=reporting",
            "-c application-name=reporting",
            "--application-name=reporting",
            "-c Application_Name=reporting"
        ]
    )
    func userApplicationNameWins(options: String) throws {
        let conninfo = try build(options: options, applicationName: "TablePro")

        #expect(!conninfo.contains("fallback_application_name"))
        #expect(conninfo.contains("options="))
    }

    @Test(
        "An option that only mentions application_name in its value still gets the fallback",
        arguments: ["-c search_path=application_name,public", "--search-path=application_name", "-c statement_timeout=0"]
    )
    func valuesDoNotNameTheApplication(options: String) throws {
        #expect(try build(options: options, applicationName: "TablePro").contains("fallback_application_name='TablePro'"))
    }

    @Test("Each setting in the options is read by its name, in every spelling the server takes")
    func readsSettingNames() {
        #expect(
            LibPQConnectionString.settingNames(in: "-c Search_Path=x -cstatement_timeout=0 --work-mem=64MB -c")
                == ["search_path", "statement_timeout", "work_mem"]
        )
    }

    @Test("A quote or backslash in the application name is escaped")
    func escapesApplicationName() throws {
        #expect(try build(applicationName: "o'brien\\x").contains("fallback_application_name='o\\'brien\\\\x'"))
    }

    @Test("A metadata connection is named apart from the session, and anything else is the session")
    func namesEachPurpose() {
        #expect(LibPQConnectionString.applicationName(forPurpose: "metadata") == "TablePro Metadata")
        #expect(LibPQConnectionString.applicationName(forPurpose: "session") == "TablePro")
        #expect(LibPQConnectionString.applicationName(forPurpose: nil) == "TablePro")
        #expect(LibPQConnectionString.applicationName(forPurpose: "other") == "TablePro")
    }

    @Test("Both names fit the server's 63-byte limit and are plain ASCII")
    func namesFitTheServerLimit() {
        for name in [LibPQConnectionString.sessionApplicationName, LibPQConnectionString.metadataApplicationName] {
            #expect(name.utf8.count <= 63)
            #expect(name.allSatisfy { $0.isASCII })
        }
    }

    @Test("UTF8 and its PostgreSQL 8.0 name UNICODE both count as the pinned encoding")
    func recognizesReportedEncoding() {
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "UTF8"))
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "UNICODE"))
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "utf8"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: "EUC_JP"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: "SQL_ASCII"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: nil))
    }
}
