import Foundation
import TableProPluginKit
import TableProTeradataCore
import Testing

struct TeradataSSLMappingTests {
    private func source(_ path: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The remaining millisecond budget wins and keeps its precision")
    func connectTimeoutMillisecondsWin() {
        let timeout = TeradataConnectTimeout(additionalFields: [
            "connectTimeoutMilliseconds": "4321",
            "connectTimeoutSeconds": "9"
        ])

        #expect(timeout.milliseconds == 4_321)
    }

    @Test("Legacy seconds are accepted and invalid input keeps the driver default")
    func connectTimeoutFallback() {
        #expect(TeradataConnectTimeout(additionalFields: ["connectTimeoutSeconds": "12"]).milliseconds == 12_000)
        #expect(TeradataConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "bad"]).milliseconds == 20_000)
        #expect(TeradataConnectTimeout(additionalFields: ["connectTimeoutSeconds": "0"]).milliseconds == 1)
        #expect(
            TeradataConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int64.min)]).milliseconds == 1
        )
    }

    @Test("Only a server refusal may make the optional VERSION probe non-fatal")
    func versionProbeFailurePolicy() {
        #expect(TeradataVersionProbe.mayIgnore(TeradataWireError.server(code: 3_523, message: "denied")))
        #expect(!TeradataVersionProbe.mayIgnore(TeradataWireError.connectionFailed("timed out")))
        #expect(!TeradataVersionProbe.mayIgnore(TeradataWireError.truncated("silent socket")))
        #expect(!TeradataVersionProbe.mayIgnore(TeradataWireError.cancelled))
        #expect(!TeradataVersionProbe.mayIgnore(CancellationError()))
    }

    @Test("Cancellation closes Teradata I/O and VERSION completes before driver adoption")
    func versionProbeUsesProvisionalConnection() throws {
        let asyncConnection = try source("Plugins/TeradataDriverPlugin/TeradataAsyncConnection.swift")
        let driver = try source("Plugins/TeradataDriverPlugin/TeradataPlugin.swift")

        #expect(asyncConnection.contains("withTaskCancellationHandler"))
        #expect(asyncConnection.contains("connection.cancel()"))
        let finish = try #require(driver.range(of: "try await connection.finishConnecting()"))
        let adoption = try #require(driver.range(of: "self.connection = connection"))
        #expect(finish.lowerBound < adoption.lowerBound)
    }

    @Test("Verify CA with an empty or blank CA path is refused before any options are built")
    func verifyCaWithoutCertificateIsRefused() {
        for path in ["", "   "] {
            let error = #expect(throws: TeradataSSLConfigurationError.self) {
                _ = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyCa, caCertificatePath: path))
            }
            #expect(error == .verifyCaNeedsCertificate)
        }
    }

    @Test("The refusal names the missing CA certificate")
    func refusalMessageNamesTheCertificate() {
        let message = TeradataSSLConfigurationError.verifyCaNeedsCertificate.pluginErrorMessage
        #expect(message.contains("CA certificate"))
        #expect(TeradataSSLConfigurationError.verifyCaNeedsCertificate.errorDescription == message)
    }

    @Test("Verify CA with a CA path checks the chain but not the hostname")
    func verifyCaWithCertificateMaps() throws {
        let options = try TeradataSSLMapping.tlsOptions(
            for: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/certs/ca.pem")
        )
        #expect(options.verifiesCertificate)
        #expect(!options.verifiesHostname)
        #expect(options.caCertificatePath == "/certs/ca.pem")
        #expect(options.modeLabel == "VERIFY-CA")
    }

    @Test("Verify Identity with no CA path is not refused")
    func verifyIdentityWithoutCertificateMaps() throws {
        let options = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyIdentity))
        #expect(options.verifiesCertificate)
        #expect(options.verifiesHostname)
        #expect(options.caCertificatePath.isEmpty)
    }

    @Test("Disabled and Required ignore the CA path")
    func nonVerifyingModesAreNotRefused() throws {
        let disabled = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .disabled))
        #expect(!disabled.enabled)
        let required = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .required))
        #expect(required.enabled)
        #expect(!required.verifiesCertificate)
    }
}
