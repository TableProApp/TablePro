import Foundation
@testable import TableProMobile
import TableProModels
import TableProMSSQLCore
import Testing

@Suite("DriverSSLConfiguration")
struct DriverSSLConfigurationTests {
    @Test("legacy bool with no configuration maps to require when enabled")
    func legacyBoolEnabled() {
        let ssl = DriverSSLConfiguration(sslEnabled: true, configuration: nil)
        #expect(ssl.mode == .require)
        #expect(ssl.isEnabled)
        #expect(!ssl.verifiesCertificate)
        #expect(ssl.caCertificatePath == nil)
    }

    @Test("legacy bool with no configuration maps to disable when off")
    func legacyBoolDisabled() {
        let ssl = DriverSSLConfiguration(sslEnabled: false, configuration: nil)
        #expect(ssl.mode == .disable)
        #expect(!ssl.isEnabled)
    }

    @Test("configuration mode is authoritative over the legacy bool")
    func configurationWins() {
        let config = SSLConfiguration(mode: .verifyFull, caCertificatePath: "/tmp/ca.pem")
        let ssl = DriverSSLConfiguration(sslEnabled: false, configuration: config)
        #expect(ssl.mode == .verifyFull)
        #expect(ssl.verifiesCertificate)
        #expect(ssl.verifiesHostname)
        #expect(ssl.caCertificatePath == "/tmp/ca.pem")
    }

    @Test("verifiesCertificate is true only for verify modes")
    func verifiesCertificate() {
        #expect(!DriverSSLConfiguration(mode: .disable).verifiesCertificate)
        #expect(!DriverSSLConfiguration(mode: .require).verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyCa).verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyFull).verifiesCertificate)
    }

    @Test("verifiesHostname is true only for verifyFull")
    func verifiesHostname() {
        #expect(!DriverSSLConfiguration(mode: .verifyCa).verifiesHostname)
        #expect(DriverSSLConfiguration(mode: .verifyFull).verifiesHostname)
    }

    @Test("postgres sslmode mirrors libpq mapping")
    func postgresMapping() {
        #expect(DriverSSLConfiguration(mode: .disable).postgresSSLMode == "disable")
        #expect(DriverSSLConfiguration(mode: .require).postgresSSLMode == "require")
        #expect(DriverSSLConfiguration(mode: .verifyCa).postgresSSLMode == "verify-ca")
        #expect(DriverSSLConfiguration(mode: .verifyFull).postgresSSLMode == "verify-full")
    }

    @Test("SQL Server encryption never downgrades verify modes to plaintext, and disable still encrypts the login")
    func mssqlMapping() {
        #expect(DriverSSLConfiguration(mode: .disable).mssqlEncryptionLevel == .request)
        #expect(DriverSSLConfiguration(mode: .require).mssqlEncryptionLevel == .require)
        #expect(DriverSSLConfiguration(mode: .verifyCa).mssqlEncryptionLevel == .require)
        #expect(DriverSSLConfiguration(mode: .verifyFull).mssqlEncryptionLevel == .require)
    }

    @Test("A Mac Preferred asks libpq for prefer and SQL Server for request, and Required still requires")
    func preferredMapping() {
        let preferred = DriverSSLConfiguration(mode: .require, isPreferred: true)
        #expect(preferred.postgresSSLMode == "prefer")
        #expect(preferred.mssqlEncryptionLevel == .request)

        let required = DriverSSLConfiguration(mode: .require)
        #expect(required.postgresSSLMode == "require")
        #expect(required.mssqlEncryptionLevel == .require)
    }

    @Test("A synced Mac Preferred reaches the mapping, and a verify mode is never Preferred")
    func storedPreferredIsCarried() {
        let stored = DriverSSLConfiguration(
            sslEnabled: true,
            configuration: SSLConfiguration(mode: .require, isMacPreferred: true)
        )
        #expect(stored.isPreferred)
        #expect(stored.postgresSSLMode == "prefer")

        let verifying = DriverSSLConfiguration(mode: .verifyFull, isPreferred: true)
        #expect(!verifying.isPreferred)
        #expect(verifying.postgresSSLMode == "verify-full")
    }

    @Test("The SQL Server driver opens a synced Mac Preferred with request and Required with require")
    func mssqlDriverReadsPreferred() {
        #expect(mssqlEncryptionLevel(SSLConfiguration(mode: .require, isMacPreferred: true)) == .request)
        #expect(mssqlEncryptionLevel(SSLConfiguration(mode: .require)) == .require)
    }

    @Test("The SQL Server driver refuses a synced verify mode it cannot honour before dialing", arguments: [
        SSLConfiguration.SSLMode.verifyCa, .verifyFull
    ])
    func mssqlDriverRefusesVerifyModes(mode: SSLConfiguration.SSLMode) async {
        let driver = MSSQLDriver(
            connection: DatabaseConnection(
                type: .mssql,
                host: "sql.example.com",
                port: 1_433,
                sslEnabled: true,
                sslConfiguration: SSLConfiguration(mode: mode, caCertificatePath: "/Users/alice/corp-ca.pem")
            ),
            password: "secret"
        )

        #expect(driver.options.certificateVerification.needsAuthority)
        await #expect {
            try await driver.connect()
        } throws: { error in
            (error as? DatabaseError)?.message == MSSQLDriver.verifyModeUnavailableMessage
        }
    }

    @Test("The SQL Server driver checks no certificate only where the mode asks for none")
    func mssqlCertificateVerificationMapping() {
        #expect(DriverSSLConfiguration(mode: .disable).mssqlCertificateVerification == .none)
        #expect(DriverSSLConfiguration(mode: .require).mssqlCertificateVerification == .none)
        #expect(DriverSSLConfiguration(mode: .verifyCa).mssqlCertificateVerification == .chain)
        #expect(DriverSSLConfiguration(mode: .verifyFull).mssqlCertificateVerification == .chainAndHostname)
    }

    private func mssqlEncryptionLevel(_ configuration: SSLConfiguration) -> MSSQLEncryptionLevel {
        MSSQLDriver(
            connection: DatabaseConnection(
                type: .mssql,
                host: "sql.example.com",
                port: 1_433,
                sslEnabled: true,
                sslConfiguration: configuration
            ),
            password: "secret"
        ).options.encryptionLevel
    }

    @Test("CA path is ignored for non-verify modes")
    func caIgnoredWithoutVerification() {
        let path = NSTemporaryDirectory() + "tablepro-ca-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("cert".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let requireMode = DriverSSLConfiguration(mode: .require, caCertificatePath: path)
        #expect(requireMode.existingCACertificatePath == nil)
    }

    @Test("CA path is used for verify modes only when the file exists on device")
    func caUsedWhenPresent() {
        let path = NSTemporaryDirectory() + "tablepro-ca-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("cert".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let present = DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: path)
        #expect(present.existingCACertificatePath == path)

        let missing = DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: "/does/not/exist.pem")
        #expect(missing.existingCACertificatePath == nil)
    }

    @Test("client certificate and key are used without requiring server verification")
    func clientCertificateIndependentOfVerification() {
        let certPath = NSTemporaryDirectory() + "tablepro-cert-\(UUID().uuidString).pem"
        let keyPath = NSTemporaryDirectory() + "tablepro-key-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: certPath, contents: Data("cert".utf8))
        FileManager.default.createFile(atPath: keyPath, contents: Data("key".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        let ssl = DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: certPath,
            clientKeyPath: keyPath
        )
        #expect(ssl.existingClientCertificatePath == certPath)
        #expect(ssl.existingClientKeyPath == keyPath)
    }

    @Test("missing or empty client certificate paths resolve to nil")
    func clientCertificateMissing() {
        let absent = DriverSSLConfiguration(
            mode: .verifyFull,
            clientCertificatePath: "/does/not/exist.pem",
            clientKeyPath: ""
        )
        #expect(absent.existingClientCertificatePath == nil)
        #expect(absent.existingClientKeyPath == nil)
        #expect(DriverSSLConfiguration(mode: .require).existingClientCertificatePath == nil)
    }

    @Test("A configuration read from the connection names no server, and materialized certificates keep the name")
    func serverNameSurvivesMaterializing() {
        #expect(DriverSSLConfiguration(sslEnabled: true, configuration: nil).serverName == nil)
        #expect(DriverSSLConfiguration(sslEnabled: true, configuration: SSLConfiguration(mode: .verifyFull)).serverName == nil)

        var ssl = DriverSSLConfiguration(mode: .verifyFull)
        ssl.serverName = "db.example.com"
        let materialized = ssl.applying(MaterializedCertificates(
            caCertificatePath: "/tmp/ca.pem",
            clientCertificatePath: nil,
            clientKeyPath: nil
        ))
        #expect(materialized.serverName == "db.example.com")
        #expect(materialized.caCertificatePath == "/tmp/ca.pem")
    }
}
