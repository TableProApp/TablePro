import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import TableProPluginKit
import Testing

struct OracleSSLMappingTests {
    // What the plugin dials with: the mode the app hands it, as the plugin maps it on connect.
    private func tlsDescription(_ ssl: DriverSSLConfiguration, serverName: String? = nil) -> OracleTLSDescription {
        ssl.pluginConfiguration.oracleTLSDescription(serverName: serverName)
    }

    private func pluginConfig(
        for connection: DatabaseConnection,
        preTunnelHost: String? = nil
    ) throws -> DriverConnectionConfig {
        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil, preTunnelHost: preTunnelHost)
        let backed = try #require(driver as? OracleBackedDriver)
        return try #require(backed.plugin as? OraclePluginDriver).config
    }

    @Test("Every SSL mode maps to the matching Oracle TLS mode")
    func modesMap() {
        #expect(tlsDescription(DriverSSLConfiguration(mode: .disable)).mode == .disabled)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .require)).mode == .required)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .verifyCa)).mode == .verifyCA)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .verifyFull)).mode == .verifyIdentity)
    }

    @Test("A Mac Preferred dials plain TCP as the Mac does, and Required still dials TCPS")
    func preferredDialsPlainTCP() {
        #expect(tlsDescription(DriverSSLConfiguration(mode: .require, isPreferred: true)).mode == .disabled)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .require)).mode == .required)
    }

    @Test("The driver opens a synced Mac Preferred in plain TCP")
    func driverReadsPreferred() throws {
        let config = try pluginConfig(for: DatabaseConnection(
            type: .oracle,
            host: "db.example.com",
            port: 1_521,
            sslEnabled: true,
            sslConfiguration: TableProModels.SSLConfiguration(mode: .require, isMacPreferred: true)
        ))
        #expect(config.ssl.oracleTLSDescription(serverName: config.tunneledServerName).mode == .disabled)
    }

    @Test("Behind a tunnel the factory names the saved host for the certificate check, and otherwise names none")
    func factoryPassesThePreTunnelHost() throws {
        let connection = DatabaseConnection(
            type: .oracle,
            host: "127.0.0.1",
            port: 49_152,
            sslEnabled: true,
            sslConfiguration: TableProModels.SSLConfiguration(mode: .verifyFull)
        )

        let tunneled = try pluginConfig(for: connection, preTunnelHost: "db.example.com")
        let direct = try pluginConfig(for: connection)

        #expect(tunneled.ssl.oracleTLSDescription(serverName: tunneled.tunneledServerName).serverName == "db.example.com")
        #expect(direct.ssl.oracleTLSDescription(serverName: direct.tunneledServerName).serverName == nil)
    }

    @Test("Only the verify modes are treated as verifying the certificate")
    func verifyModes() {
        #expect(!tlsDescription(DriverSSLConfiguration(mode: .require)).verifiesCertificate)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .verifyCa)).verifiesCertificate)
        #expect(tlsDescription(DriverSSLConfiguration(mode: .verifyFull)).verifiesCertificate)
    }

    @Test("Client certificate and key paths survive the trip from a stored connection")
    func clientMaterialIsCarried() {
        let configuration = TableProModels.SSLConfiguration(
            mode: .verifyFull,
            caCertificatePath: "/certs/ca.pem",
            clientCertificatePath: "/certs/client.pem",
            clientKeyPath: "/certs/client.key"
        )
        let tls = tlsDescription(DriverSSLConfiguration(sslEnabled: true, configuration: configuration))
        #expect(tls.caCertificatePath == "/certs/ca.pem")
        #expect(tls.clientCertificatePath == "/certs/client.pem")
        #expect(tls.clientKeyPath == "/certs/client.key")
    }

    @Test("Empty stored paths are absent rather than empty strings")
    func emptyPathsBecomeNil() {
        let configuration = TableProModels.SSLConfiguration(mode: .require, caCertificatePath: "")
        #expect(tlsDescription(DriverSSLConfiguration(sslEnabled: true, configuration: configuration)).caCertificatePath == nil)
    }

    @Test("A stored Verify CA connection with no CA is refused before it connects")
    func verifyCaWithoutCertificateIsRefused() {
        #expect(throws: OracleCoreError.certificateAuthorityRequired) {
            try OracleTLSMapper.tls(for: tlsDescription(DriverSSLConfiguration(mode: .verifyCa)))
        }
    }

    @Test("The refusal points at Verify Identity, which works on this device without a CA")
    func refusalPointsAtVerifyIdentity() async throws {
        let driver = try IOSDriverFactory().createDriver(
            for: DatabaseConnection(
                type: .oracle,
                host: "127.0.0.1",
                port: 1_521,
                sslEnabled: true,
                sslConfiguration: TableProModels.SSLConfiguration(mode: .verifyCa)
            ),
            password: nil
        )

        let error = await #expect(throws: DatabaseError.self) { try await driver.connect() }

        let message = error?.localizedDescription
        #expect(message == DriverSSLConfiguration.oracleVerifyCaUnavailableMessage)
        #expect(message?.contains("Verify Identity") == true)
        #expect(message?.contains("Network") == false)
    }

    @Test("Verify Identity with no CA is not refused")
    func verifyIdentityWithoutCertificateIsNotRefused() throws {
        _ = try OracleTLSMapper.tls(for: tlsDescription(DriverSSLConfiguration(mode: .verifyFull)))
    }

    @Test("A connection with no SSL configuration carries no certificate paths")
    func legacyBoolCarriesNoPaths() {
        let tls = tlsDescription(DriverSSLConfiguration(sslEnabled: true, configuration: nil))
        #expect(tls.mode == .required)
        #expect(tls.caCertificatePath == nil)
        #expect(tls.clientCertificatePath == nil)
        #expect(tls.clientKeyPath == nil)
    }
}
