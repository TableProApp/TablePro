import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("PostgreSQL connection string")
struct PostgreSQLConnectionStringTests {
    private func temporaryFile() -> String {
        let path = NSTemporaryDirectory() + "tablepro-pg-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("pem".utf8))
        return path
    }

    private func build(ssl: DriverSSLConfiguration) throws -> String {
        try PostgreSQLConnectionString.build(
            host: "db.example.com",
            port: 5432,
            database: "app",
            user: "postgres",
            password: "hunter2",
            ssl: ssl
        )
    }

    @Test("the base parameters are always present")
    func baseParameters() throws {
        let connStr = try build(ssl: .disabled)

        #expect(connStr.contains("host='db.example.com'"))
        #expect(connStr.contains("port='5432'"))
        #expect(connStr.contains("dbname='app'"))
        #expect(connStr.contains("user='postgres'"))
        #expect(connStr.contains("password='hunter2'"))
        #expect(connStr.contains("sslmode='disable'"))
    }

    @Test("libpq is asked for the keepalive while it connects; the idle time it drops is set on the socket after")
    func asksLibpqForTheKeepalive() throws {
        let connStr = try build(ssl: .disabled)

        #expect(connStr.contains("keepalives='1'"))
        #expect(connStr.contains("keepalives_idle='60'"))
        #expect(connStr.contains("keepalives_interval='10'"))
        #expect(connStr.contains("keepalives_count='3'"))
    }

    @Test("the session is pinned to UTF8 in the startup packet, whatever the database's encoding")
    func pinsClientEncoding() throws {
        #expect(try build(ssl: .disabled).contains("client_encoding='UTF8'"))
    }

    @Test("A Mac Preferred reaches libpq as prefer, and Required as require")
    func preferredIsPrefer() throws {
        #expect(try build(ssl: DriverSSLConfiguration(mode: .require, isPreferred: true)).contains("sslmode='prefer'"))
        #expect(try build(ssl: DriverSSLConfiguration(mode: .require)).contains("sslmode='require'"))
    }

    @Test("a client certificate and key reach libpq as sslcert and sslkey")
    func clientCertificateIsSent() throws {
        let certPath = temporaryFile()
        let keyPath = temporaryFile()
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let connStr = try build(ssl: DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: certPath,
            clientKeyPath: keyPath
        ))

        #expect(connStr.contains("sslcert='\(certPath)'"))
        #expect(connStr.contains("sslkey='\(keyPath)'"))
    }

    @Test("a CA certificate is sent only when the mode verifies it")
    func caOnlyWhenVerifying() throws {
        let caPath = temporaryFile()
        defer { try? FileManager.default.removeItem(atPath: caPath) }

        let requiring = try build(ssl: DriverSSLConfiguration(mode: .require, caCertificatePath: caPath))
        #expect(!requiring.contains("sslrootcert"))

        let verifying = try build(ssl: DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: caPath))
        #expect(verifying.contains("sslrootcert='\(caPath)'"))
    }

    @Test("a certificate path that does not exist is left out entirely")
    func missingFileIsOmitted() throws {
        let connStr = try build(ssl: DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: "/does/not/exist.pem",
            clientKeyPath: "/does/not/exist.key"
        ))

        #expect(!connStr.contains("sslcert"))
        #expect(!connStr.contains("sslkey"))
    }

    @Test("quotes and backslashes in values are escaped")
    func escapesValues() throws {
        let connStr = try PostgreSQLConnectionString.build(
            host: "db",
            port: 5432,
            database: "app",
            user: "o'brien",
            password: "back\\slash",
            ssl: .disabled
        )

        #expect(connStr.contains("user='o\\'brien'"))
        #expect(connStr.contains("password='back\\\\slash'"))
    }

    @Test(
        "A NUL in any setting fails the connect and names the setting, instead of libpq reading a cut string",
        arguments: ["host", "dbname", "user", "password"]
    )
    func refusesANULCharacter(keyword: String) {
        let value = "a\u{0}b"
        let error = #expect(throws: PostgreSQLError.self) {
            try PostgreSQLConnectionString.build(
                host: keyword == "host" ? value : "db.example.com",
                port: 5_432,
                database: keyword == "dbname" ? value : "app",
                user: keyword == "user" ? value : "postgres",
                password: keyword == "password" ? value : "hunter2",
                ssl: .disabled
            )
        }
        #expect(error?.localizedDescription.contains(keyword) == true)
    }

    @Test("A line break stays inside the quotes, where libpq reads it as data")
    func keepsALineBreakAsData() throws {
        let connStr = try PostgreSQLConnectionString.build(
            host: "db",
            port: 5_432,
            database: "app",
            user: "postgres",
            password: "a\nhost=evil",
            ssl: .disabled
        )

        #expect(connStr.contains("password='a\nhost=evil'"))
    }

    @Test("Through a tunnel, libpq checks the certificate against the server name and dials the loopback")
    func tunneledConnectionNamesTheServer() throws {
        let connStr = try PostgreSQLConnectionString.build(
            host: "127.0.0.1",
            port: 49_152,
            database: "app",
            user: "iam_user",
            password: "signed-token",
            ssl: DriverSSLConfiguration(mode: .verifyFull, serverName: "mydb.abc123.us-east-1.rds.amazonaws.com")
        )

        #expect(connStr.contains("host='mydb.abc123.us-east-1.rds.amazonaws.com'"))
        #expect(connStr.contains("hostaddr='127.0.0.1'"))
        #expect(!connStr.contains("host='127.0.0.1'"))
        #expect(connStr.contains("port='49152'"))
    }

    @Test("No server name, the same name, or a dial host that is not an address sends host alone")
    func hostaddrOnlyForAnAddress() throws {
        #expect(try !build(ssl: .disabled).contains("hostaddr"))
        #expect(try !build(ssl: DriverSSLConfiguration(mode: .require, serverName: "db.example.com")).contains("hostaddr"))

        let named = try build(ssl: DriverSSLConfiguration(mode: .verifyFull, serverName: "other.example.com"))
        #expect(named.contains("host='db.example.com'"))
        #expect(!named.contains("hostaddr"))
    }
}
