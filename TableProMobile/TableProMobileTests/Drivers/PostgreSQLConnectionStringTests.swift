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

    private func build(ssl: DriverSSLConfiguration) -> String {
        PostgreSQLConnectionString.build(
            host: "db.example.com",
            port: 5432,
            database: "app",
            user: "postgres",
            password: "hunter2",
            ssl: ssl
        )
    }

    @Test("the base parameters are always present")
    func baseParameters() {
        let connStr = build(ssl: .disabled)

        #expect(connStr.contains("host='db.example.com'"))
        #expect(connStr.contains("port='5432'"))
        #expect(connStr.contains("dbname='app'"))
        #expect(connStr.contains("user='postgres'"))
        #expect(connStr.contains("password='hunter2'"))
        #expect(connStr.contains("sslmode='disable'"))
    }

    @Test("a client certificate and key reach libpq as sslcert and sslkey")
    func clientCertificateIsSent() {
        let certPath = temporaryFile()
        let keyPath = temporaryFile()
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let connStr = build(ssl: DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: certPath,
            clientKeyPath: keyPath
        ))

        #expect(connStr.contains("sslcert='\(certPath)'"))
        #expect(connStr.contains("sslkey='\(keyPath)'"))
    }

    @Test("a CA certificate is sent only when the mode verifies it")
    func caOnlyWhenVerifying() {
        let caPath = temporaryFile()
        defer { try? FileManager.default.removeItem(atPath: caPath) }

        let requiring = build(ssl: DriverSSLConfiguration(mode: .require, caCertificatePath: caPath))
        #expect(!requiring.contains("sslrootcert"))

        let verifying = build(ssl: DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: caPath))
        #expect(verifying.contains("sslrootcert='\(caPath)'"))
    }

    @Test("a certificate path that does not exist is left out entirely")
    func missingFileIsOmitted() {
        let connStr = build(ssl: DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: "/does/not/exist.pem",
            clientKeyPath: "/does/not/exist.key"
        ))

        #expect(!connStr.contains("sslcert"))
        #expect(!connStr.contains("sslkey"))
    }

    @Test("quotes and backslashes in values are escaped")
    func escapesValues() {
        let connStr = PostgreSQLConnectionString.build(
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
}
